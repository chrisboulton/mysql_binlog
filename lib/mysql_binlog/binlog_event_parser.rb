module MysqlBinlog
  # A mapping array for all values that may appear in the +status+ field of
  # a query_event.
  QUERY_EVENT_STATUS_TYPES = [
    :flags2,                    # 0
    :sql_mode,                  # 1
    :catalog_deprecated,        # 2
    :auto_increment,            # 3
    :charset,                   # 4
    :time_zone,                 # 5
    :catalog,                   # 6
    :lc_time_names,             # 7
    :charset_database,          # 8
    :table_map_for_update,      # 9
  ]

  # A mapping hash for all values that may appear in the +flags2+ field of
  # a query_event.
  QUERY_EVENT_FLAGS2 = {
    :auto_is_null           => 1 << 14,
    :not_autocommit         => 1 << 19,
    :no_foreign_key_checks  => 1 << 26,
    :relaxed_unique_checks  => 1 << 27,
  }

  INTVAR_EVENT_INTVAR_TYPES = [
    nil,
    :last_insert_id,
    :insert_id,
  ]

  class BinlogEventParser
    attr_accessor :binlog
    attr_accessor :reader
    attr_accessor :parser

    def initialize(binlog_instance)
      @binlog = binlog_instance
      @reader = binlog_instance.reader
      @parser = binlog_instance.field_parser
      @table_map = {}
    end

    # Parse fields for a +Format_description+ event.
    def format_description_event(header)
      fields = {}
      fields[:binlog_version]   = parser.read_uint16
      fields[:server_version]   = parser.read_nstringz(50)
      fields[:create_timestamp] = parser.read_uint32
      fields[:header_length]    = parser.read_uint8
      fields
    end

    # Parse fields for a +Rotate+ event.
    def rotate_event(header)
      fields = {}
      fields[:pos] = parser.read_uint64
      name_length = reader.remaining(header)
      fields[:name] = parser.read_nstring(name_length)
      fields
    end

    # Parse a dynamic +status+ structure within a query_event, which consists
    # of a status_length (uint16) followed by a number of status variables
    # (determined by the +status_length+) each of which consist of:
    # * A type code (uint8), one of QUERY_EVENT_STATUS_TYPES.
    # * The content itself, determined by the type. Additional processing is
    #   required based on the type.
    def _query_event_status(header, fields)
      status = {}
      status_length = parser.read_uint16
      end_position = reader.position + status_length
      while reader.position < end_position
        status_type = QUERY_EVENT_STATUS_TYPES[parser.read_uint8]
        status[status_type] = case status_type
        when :flags2
          parser.read_uint32_bitmap_by_name(QUERY_EVENT_FLAGS2)
        when :sql_mode
          parser.read_uint64
        when :catalog_deprecated
          parser.read_lpstringz
        when :auto_increment
          {
            :increment => parser.read_uint16,
            :offset    => parser.read_uint16,
          }
        when :charset
          {
            :character_set_client => parser.read_uint16,
            :collation_connection => parser.read_uint16,
            :collation_server     => parser.read_uint16,
          }
        when :time_zone
          parser.read_lpstring
        when :catalog
          parser.read_lpstring
        when :lc_time_names
          parser.read_uint16
        when :charset_database
          parser.read_uint16
        when :table_map_for_update
          parser.read_uint64
        end
      end
      status
    end

    # Parse fields for a +Query+ event.
    def query_event(header)
      fields = {}
      fields[:thread_id] = parser.read_uint32
      fields[:elapsed_time] = parser.read_uint32
      db_length = parser.read_uint8
      fields[:error_code] = parser.read_uint16
      fields[:status] = _query_event_status(header, fields)
      fields[:db] = parser.read_nstringz(db_length + 1)
      query_length = reader.remaining(header)
      fields[:query] = reader.read([query_length, binlog.max_query_length].min)
      fields
    end

    # Parse fields for an +Intvar+ event.
    def intvar_event(header)
      fields = {}

      fields[:intvar_type]  = parser.read_uint8
      fields[:intvar_name]  = INTVAR_EVENT_INTVAR_TYPES[fields[:intvar_type]]
      fields[:intvar_value] = parser.read_uint64

      fields
    end

    # Parse fields for an +Xid+ event.
    def xid_event(header)
      fields = {}
      fields[:xid] = parser.read_uint64
      fields
    end

    # Parse fields for an +Rand+ event.
    def rand_event(header)
      fields = {}
      fields[:seed1] = parser.read_uint64
      fields[:seed2] = parser.read_uint64
      fields
    end

    # Parse column metadata within a table map event.
    def _table_map_event_column_metadata(columns_type)
      length = parser.read_varint
      columns_type.map do |c|
        parser.read_mysql_type_metadata(c)
      end
    end

    # Parse fields for a +Table_map+ event.
    def table_map_event(header)
      fields = {}
      fields[:table_id] = parser.read_uint48
      fields[:flags] = parser.read_uint16
      map_entry = @table_map[fields[:table_id]] = {}
      map_entry[:db] = parser.read_lpstringz
      map_entry[:table] = parser.read_lpstringz
      columns = parser.read_varint
      columns_type = parser.read_uint8_array(columns).map { |c| MYSQL_TYPES[c] }
      columns_metadata = _table_map_event_column_metadata(columns_type)
      columns_nullable = parser.read_bit_array(columns)

      map_entry[:columns] = columns.times.map do |c|
        {
          :type     => columns_type[c],
          :nullable => columns_nullable[c],
          :metadata => columns_metadata[c],
        }
      end

      fields[:map_entry] = map_entry
      fields
    end

    # Parse a single row image, which is comprised of a series of columns. Not
    # all columns are present in the row image, the columns_used array of true
    # and false values identifies which columns are present.
    def _generic_rows_event_row_image(header, fields, columns_used)
      row_image = []
      columns_null = parser.read_bit_array(fields[:table][:columns].size)
      fields[:table][:columns].each_with_index do |column, column_index|
        if !columns_used[column_index]
          row_image << nil
        elsif columns_null[column_index]
          row_image << { column => nil }
        else
          row_image << {
            column => parser.read_mysql_type(column[:type], column[:metadata])
          }
        end
      end
      row_image
    end

    # Parse the row images present in a row-based replication row event. This
    # is rather incomplete right now due missing support for many MySQL types,
    # but can parse some basic events.
    def _generic_rows_event_row_images(header, fields, columns_used)
      row_images = []
      end_position = reader.position + reader.remaining(header)
      while reader.position < end_position
        row_image = {}
        case EVENT_TYPES[header[:event_type]]
        when :write_rows_event
          row_image[:after]  = _generic_rows_event_row_image(header, fields, columns_used[:after])
        when :delete_rows_event
          row_image[:before] = _generic_rows_event_row_image(header, fields, columns_used[:before])
        when :update_rows_event
          row_image[:before] = _generic_rows_event_row_image(header, fields, columns_used[:before])
          row_image[:after]  = _generic_rows_event_row_image(header, fields, columns_used[:after])
        end
        row_images << row_image
      end
      row_images
    end

    # Parse fields for any of the row-based replication row events:
    # * +Write_rows+ which is used for +INSERT+.
    # * +Update_rows+ which is used for +UPDATE+.
    # * +Delete_rows+ which is used for +DELETE+.
    def generic_rows_event(header)
      fields = {}
      table_id = parser.read_uint48
      fields[:table] = @table_map[table_id]
      fields[:flags] = parser.read_uint16
      columns = parser.read_varint
      columns_used = {}
      case EVENT_TYPES[header[:event_type]]
      when :write_rows_event
        columns_used[:after]  = parser.read_bit_array(columns)
      when :delete_rows_event
        columns_used[:before] = parser.read_bit_array(columns)
      when :update_rows_event
        columns_used[:before] = parser.read_bit_array(columns)
        columns_used[:after]  = parser.read_bit_array(columns)
      end
      fields[:row_image] = _generic_rows_event_row_images(header, fields, columns_used)
      fields
    end

    alias :write_rows_event  :generic_rows_event
    alias :update_rows_event :generic_rows_event
    alias :delete_rows_event :generic_rows_event

  end
end