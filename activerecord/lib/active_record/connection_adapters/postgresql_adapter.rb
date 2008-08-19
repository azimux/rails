require 'active_record/connection_adapters/abstract_adapter'

begin
  require_library_or_gem 'pg'
rescue LoadError => e
  begin
    require_library_or_gem 'postgres'
    class PGresult
      alias_method :nfields, :num_fields unless self.method_defined?(:nfields)
      alias_method :ntuples, :num_tuples unless self.method_defined?(:ntuples)
      alias_method :ftype, :type unless self.method_defined?(:ftype)
      alias_method :cmd_tuples, :cmdtuples unless self.method_defined?(:cmd_tuples)
    end
  rescue LoadError
    raise e
  end
end

module ActiveRecord
  class Base
    # Establishes a connection to the database that's used by all Active Record objects
    def self.postgresql_connection(config) # :nodoc:
      config = config.symbolize_keys
      host     = config[:host]
      port     = config[:port] || 5432
      username = config[:username].to_s
      password = config[:password].to_s

      if config.has_key?(:database)
        database = config[:database]
      else
        raise ArgumentError, "No database specified. Missing argument: database."
      end

      # The postgres drivers don't allow the creation of an unconnected PGconn object,
      # so just pass a nil connection object for the time being.
      ConnectionAdapters::PostgreSQLAdapter.new(nil, logger, [host, port, nil, nil, database, username, password], config)
    end
  end

  module ConnectionAdapters
    # PostgreSQL-specific extensions to column definitions in a table.
    class PostgreSQLColumn < Column #:nodoc:
      # Instantiates a new PostgreSQL column definition in a table.
      def initialize(name, default, sql_type = nil, null = true)
        super(name, self.class.extract_value_from_default(default), sql_type, null)
      end

      private
        def extract_limit(sql_type)
          case sql_type
          when /^bigint/i;    8
          when /^smallint/i;  2
          else super
          end
        end

        # Extracts the scale from PostgreSQL-specific data types.
        def extract_scale(sql_type)
          # Money type has a fixed scale of 2.
          sql_type =~ /^money/ ? 2 : super
        end

        # Extracts the precision from PostgreSQL-specific data types.
        def extract_precision(sql_type)
          # Actual code is defined dynamically in PostgreSQLAdapter.connect
          # depending on the server specifics
          super
        end
  
        # Escapes binary strings for bytea input to the database.
        def self.string_to_binary(value)
          if PGconn.respond_to?(:escape_bytea)
            self.class.module_eval do
              define_method(:string_to_binary) do |value|
                PGconn.escape_bytea(value) if value
              end
            end
          else
            self.class.module_eval do
              define_method(:string_to_binary) do |value|
                if value
                  result = ''
                  value.each_byte { |c| result << sprintf('\\\\%03o', c) }
                  result
                end
              end
            end
          end
          self.class.string_to_binary(value)
        end

        # Maps PostgreSQL-specific data types to logical Rails types.
        def simplified_type(field_type)
          case field_type
            # Numeric and monetary types
            when /^(?:real|double precision)$/
              :float
            # Monetary types
            when /^money$/
              :decimal
            # Character types
            when /^(?:character varying|bpchar)(?:\(\d+\))?$/
              :string
            # Binary data types
            when /^bytea$/
              :binary
            # Date/time types
            when /^timestamp with(?:out)? time zone$/
              :datetime
            when /^interval$/
              :string
            # Geometric types
            when /^(?:point|line|lseg|box|"?path"?|polygon|circle)$/
              :string
            # Network address types
            when /^(?:cidr|inet|macaddr)$/
              :string
            # Bit strings
            when /^bit(?: varying)?(?:\(\d+\))?$/
              :string
            # XML type
            when /^xml$/
              :string
            # Arrays
            when /^\D+\[\]$/
              :string              
            # Object identifier types
            when /^oid$/
              :integer
            # Pass through all types that are not specific to PostgreSQL.
            else
              super
          end
        end
  
        # Extracts the value from a PostgreSQL column default definition.
        def self.extract_value_from_default(default)
          case default
            # Numeric types
            when /\A\(?(-?\d+(\.\d*)?\)?)\z/
              $1
            # Character types
            when /\A'(.*)'::(?:character varying|bpchar|text)\z/m
              $1
            # Character types (8.1 formatting)
            when /\AE'(.*)'::(?:character varying|bpchar|text)\z/m
              $1.gsub(/\\(\d\d\d)/) { $1.oct.chr }
            # Binary data types
            when /\A'(.*)'::bytea\z/m
              $1
            # Date/time types
            when /\A'(.+)'::(?:time(?:stamp)? with(?:out)? time zone|date)\z/
              $1
            when /\A'(.*)'::interval\z/
              $1
            # Boolean type
            when 'true'
              true
            when 'false'
              false
            # Geometric types
            when /\A'(.*)'::(?:point|line|lseg|box|"?path"?|polygon|circle)\z/
              $1
            # Network address types
            when /\A'(.*)'::(?:cidr|inet|macaddr)\z/
              $1
            # Bit string types
            when /\AB'(.*)'::"?bit(?: varying)?"?\z/
              $1
            # XML type
            when /\A'(.*)'::xml\z/m
              $1
            # Arrays
            when /\A'(.*)'::"?\D+"?\[\]\z/
              $1
            # Object identifier types
            when /\A-?\d+\z/
              $1
            else
              # Anything else is blank, some user type, or some function
              # and we can't know the value of that, so return nil.
              nil
          end
        end
    end
  end

  module ConnectionAdapters
    # The PostgreSQL adapter works both with the native C (http://ruby.scripting.ca/postgres/) and the pure
    # Ruby (available both as gem and from http://rubyforge.org/frs/?group_id=234&release_id=1944) drivers.
    #
    # Options:
    #
    # * <tt>:host</tt> - Defaults to "localhost".
    # * <tt>:port</tt> - Defaults to 5432.
    # * <tt>:username</tt> - Defaults to nothing.
    # * <tt>:password</tt> - Defaults to nothing.
    # * <tt>:database</tt> - The name of the database. No default, must be provided.
    # * <tt>:schema_search_path</tt> - An optional schema search path for the connection given as a string of comma-separated schema names.  This is backward-compatible with the <tt>:schema_order</tt> option.
    # * <tt>:encoding</tt> - An optional client encoding that is used in a <tt>SET client_encoding TO <encoding></tt> call on the connection.
    # * <tt>:min_messages</tt> - An optional client min messages that is used in a <tt>SET client_min_messages TO <min_messages></tt> call on the connection.
    # * <tt>:allow_concurrency</tt> - If true, use async query methods so Ruby threads don't deadlock; otherwise, use blocking query methods.
    class PostgreSQLAdapter < AbstractAdapter
      ADAPTER_NAME = 'PostgreSQL'.freeze

      NATIVE_DATABASE_TYPES = {
        :primary_key => "serial primary key".freeze,
        :string      => { :name => "character varying", :limit => 255 },
        :text        => { :name => "text" },
        :integer     => { :name => "integer" },
        :float       => { :name => "float" },
        :decimal     => { :name => "decimal" },
        :datetime    => { :name => "timestamp" },
        :timestamp   => { :name => "timestamp" },
        :time        => { :name => "time" },
        :date        => { :name => "date" },
        :binary      => { :name => "bytea" },
        :boolean     => { :name => "boolean" }
      }

      # Returns 'PostgreSQL' as adapter name for identification purposes.
      def adapter_name
        ADAPTER_NAME
      end

      # Initializes and connects a PostgreSQL adapter.
      def initialize(connection, logger, connection_parameters, config)
        super(connection, logger)
        @connection_parameters, @config = connection_parameters, config

        connect
      end

      # Is this connection alive and ready for queries?
      def active?
        if @connection.respond_to?(:status)
          @connection.status == PGconn::CONNECTION_OK
        else
          # We're asking the driver, not ActiveRecord, so use @connection.query instead of #query
          @connection.query 'SELECT 1'
          true
        end
      # postgres-pr raises a NoMethodError when querying if no connection is available.
      rescue PGError, NoMethodError
        false
      end

      # Close then reopen the connection.
      def reconnect!
        if @connection.respond_to?(:reset)
          @connection.reset
          configure_connection
        else
          disconnect!
          connect
        end
      end

      # Close the connection.
      def disconnect!
        @connection.close rescue nil
      end

      def native_database_types #:nodoc:
        NATIVE_DATABASE_TYPES
      end

      # Does PostgreSQL support migrations?
      def supports_migrations?
        true
      end

      # Does PostgreSQL support standard conforming strings?
      def supports_standard_conforming_strings?
        # Temporarily set the client message level above error to prevent unintentional
        # error messages in the logs when working on a PostgreSQL database server that
        # does not support standard conforming strings.
        client_min_messages_old = client_min_messages
        self.client_min_messages = 'panic'

        # postgres-pr does not raise an exception when client_min_messages is set higher
        # than error and "SHOW standard_conforming_strings" fails, but returns an empty
        # PGresult instead.
        has_support = query('SHOW standard_conforming_strings')[0][0] rescue false
        self.client_min_messages = client_min_messages_old
        has_support
      end

      def supports_insert_with_returning?
        postgresql_version >= 80200
      end

      # Returns the configured supported identifier length supported by PostgreSQL,
      # or report the default of 63 on PostgreSQL 7.x.
      def table_alias_length
        @table_alias_length ||= (postgresql_version >= 80000 ? query('SHOW max_identifier_length')[0][0].to_i : 63)
      end

      # QUOTING ==================================================

      # Quotes PostgreSQL-specific data types for SQL input.
      def quote(value, column = nil) #:nodoc:
        if value.kind_of?(String) && column && column.type == :binary
          "#{quoted_string_prefix}'#{column.class.string_to_binary(value)}'"
        elsif value.kind_of?(String) && column && column.sql_type =~ /^xml$/
          "xml '#{quote_string(value)}'"
        elsif value.kind_of?(Numeric) && column && column.sql_type =~ /^money$/
          # Not truly string input, so doesn't require (or allow) escape string syntax.
          "'#{value.to_s}'"
        elsif value.kind_of?(String) && column && column.sql_type =~ /^bit/
          case value
            when /^[01]*$/
              "B'#{value}'" # Bit-string notation
            when /^[0-9A-F]*$/i
              "X'#{value}'" # Hexadecimal notation
          end
        else
          super
        end
      end

      # Quotes strings for use in SQL input in the postgres driver for better performance.
      def quote_string(s) #:nodoc:
        if PGconn.respond_to?(:escape)
          self.class.instance_eval do
            define_method(:quote_string) do |s|
              PGconn.escape(s)
            end
          end
        else
          # There are some incorrectly compiled postgres drivers out there
          # that don't define PGconn.escape.
          self.class.instance_eval do
            undef_method(:quote_string)
          end
        end
        quote_string(s)
      end

      # Quotes column names for use in SQL queries.
      def quote_column_name(name) #:nodoc:
        %("#{name}")
      end

      # Quote date/time values for use in SQL input. Includes microseconds
      # if the value is a Time responding to usec.
      def quoted_date(value) #:nodoc:
        if value.acts_like?(:time) && value.respond_to?(:usec)
          "#{super}.#{sprintf("%06d", value.usec)}"
        else
          super
        end
      end

      # REFERENTIAL INTEGRITY ====================================

      def supports_disable_referential_integrity?() #:nodoc:
        version = query("SHOW server_version")[0][0].split('.')
        (version[0].to_i >= 8 && version[1].to_i >= 1) ? true : false
      rescue
        return false
      end

      def disable_referential_integrity(&block) #:nodoc:
        if supports_disable_referential_integrity?() then
          execute(tables.collect { |name| "ALTER TABLE #{quote_table_name(name)} DISABLE TRIGGER ALL" }.join(";"))
        end
        yield
      ensure
        if supports_disable_referential_integrity?() then
          execute(tables.collect { |name| "ALTER TABLE #{quote_table_name(name)} ENABLE TRIGGER ALL" }.join(";"))
        end
      end

      # DATABASE STATEMENTS ======================================

      # Executes a SELECT query and returns an array of rows. Each row is an
      # array of field values.
      def select_rows(sql, name = nil)
        select_raw(sql, name).last
      end

      # Executes an INSERT query and returns the new record's ID
      def insert(sql, name = nil, pk = nil, id_value = nil, sequence_name = nil)
        # Extract the table from the insert sql. Yuck.
        table = sql.split(" ", 4)[2].gsub('"', '')

        # Try an insert with 'returning id' if available (PG >= 8.2)
        if supports_insert_with_returning?
          pk, sequence_name = *pk_and_sequence_for(table) unless pk
          if pk
            id = select_value("#{sql} RETURNING #{quote_column_name(pk)}")
            clear_query_cache
            return id
          end
        end

        # Otherwise, insert then grab last_insert_id.
        if insert_id = super
          insert_id
        else
          # If neither pk nor sequence name is given, look them up.
          unless pk || sequence_name
            pk, sequence_name = *pk_and_sequence_for(table)
          end

          # If a pk is given, fallback to default sequence name.
          # Don't fetch last insert id for a table without a pk.
          if pk && sequence_name ||= default_sequence_name(table, pk)
            last_insert_id(table, sequence_name)
          end
        end
      end

      # create a 2D array representing the result set
      def result_as_array(res) #:nodoc:
        ary = []
        for i in 0...res.ntuples do
          ary << []
          for j in 0...res.nfields do
            ary[i] << res.getvalue(i,j)
          end
        end
        return ary
      end


      # Queries the database and returns the results in an Array-like object
      def query(sql, name = nil) #:nodoc:
        log(sql, name) do
          if @async
            res = @connection.async_exec(sql)
          else
            res = @connection.exec(sql)
          end
          return result_as_array(res)
        end
      end

      # Executes an SQL statement, returning a PGresult object on success
      # or raising a PGError exception otherwise.
      def execute(sql, name = nil)
        log(sql, name) do
          if @async
            @connection.async_exec(sql)
          else
            @connection.exec(sql)
          end
        end
      end

      # Executes an UPDATE query and returns the number of affected tuples.
      def update_sql(sql, name = nil)
        super.cmd_tuples
      end

      # Begins a transaction.
      def begin_db_transaction
        execute "BEGIN"
      end

      # Commits a transaction.
      def commit_db_transaction
        execute "COMMIT"
      end

      # Aborts a transaction.
      def rollback_db_transaction
        execute "ROLLBACK"
      end

      # SCHEMA STATEMENTS ========================================

      def recreate_database(name) #:nodoc:
        drop_database(name)
        create_database(name)
      end

      # Create a new PostgreSQL database.  Options include <tt>:owner</tt>, <tt>:template</tt>,
      # <tt>:encoding</tt>, <tt>:tablespace</tt>, and <tt>:connection_limit</tt> (note that MySQL uses
      # <tt>:charset</tt> while PostgreSQL uses <tt>:encoding</tt>).
      #
      # Example:
      #   create_database config[:database], config
      #   create_database 'foo_development', :encoding => 'unicode'
      def create_database(name, options = {})
        options = options.reverse_merge(:encoding => "utf8")

        option_string = options.symbolize_keys.sum do |key, value|
          case key
          when :owner
            " OWNER = '#{value}'"
          when :template
            " TEMPLATE = #{value}"
          when :encoding
            " ENCODING = '#{value}'"
          when :tablespace
            " TABLESPACE = #{value}"
          when :connection_limit
            " CONNECTION LIMIT = #{value}"
          else
            ""
          end
        end

        execute "CREATE DATABASE #{quote_table_name(name)}#{option_string}"
      end

      # Drops a PostgreSQL database
      #
      # Example:
      #   drop_database 'matt_development'
      def drop_database(name) #:nodoc:
        if postgresql_version >= 80200
          execute "DROP DATABASE IF EXISTS #{quote_table_name(name)}"
        else
          begin
            execute "DROP DATABASE #{quote_table_name(name)}"
          rescue ActiveRecord::StatementInvalid
            @logger.warn "#{name} database doesn't exist." if @logger
          end
        end
      end


      # Returns the list of all tables in the schema search path or a specified schema.
      def tables(name = nil)
        schemas = schema_search_path.split(/,/).map { |p| quote(p) }.join(',')
        query(<<-SQL, name).map { |row| row[0] }
          SELECT tablename
            FROM pg_tables
           WHERE schemaname IN (#{schemas})
        SQL
      end

      # Returns the list of all indexes for a table.
      def indexes(table_name, name = nil)
         schemas = schema_search_path.split(/,/).map { |p| quote(p) }.join(',')
         result = query(<<-SQL, name)
           SELECT distinct i.relname, d.indisunique, a.attname
             FROM pg_class t, pg_class i, pg_index d, pg_attribute a
           WHERE i.relkind = 'i'
             AND d.indexrelid = i.oid
             AND d.indisprimary = 'f'
             AND t.oid = d.indrelid
             AND t.relname = '#{table_name}'
             AND i.relnamespace IN (SELECT oid FROM pg_namespace WHERE nspname IN (#{schemas}) )
             AND a.attrelid = t.oid
             AND ( d.indkey[0]=a.attnum OR d.indkey[1]=a.attnum
                OR d.indkey[2]=a.attnum OR d.indkey[3]=a.attnum
                OR d.indkey[4]=a.attnum OR d.indkey[5]=a.attnum
                OR d.indkey[6]=a.attnum OR d.indkey[7]=a.attnum
                OR d.indkey[8]=a.attnum OR d.indkey[9]=a.attnum )
          ORDER BY i.relname
        SQL

        current_index = nil
        indexes = []

        result.each do |row|
          if current_index != row[0]
            indexes << IndexDefinition.new(table_name, row[0], row[1] == "t", [])
            current_index = row[0]
          end

          indexes.last.columns << row[2]
        end

        indexes
      end

      # Returns the list of all column definitions for a table.
      def columns(table_name, name = nil)
        # Limit, precision, and scale are all handled by the superclass.
        column_definitions(table_name).collect do |name, type, default, notnull|
          PostgreSQLColumn.new(name, default, type, notnull == 'f')
        end
      end

      # Returns the current database name.
      def current_database
        query('select current_database()')[0][0]
      end

      # Returns the current database encoding format.
      def encoding
        query(<<-end_sql)[0][0]
          SELECT pg_encoding_to_char(pg_database.encoding) FROM pg_database
          WHERE pg_database.datname LIKE '#{current_database}'
        end_sql
      end

      # Sets the schema search path to a string of comma-separated schema names.
      # Names beginning with $ have to be quoted (e.g. $user => '$user').
      # See: http://www.postgresql.org/docs/current/static/ddl-schemas.html
      #
      # This should be not be called manually but set in database.yml.
      def schema_search_path=(schema_csv)
        if schema_csv
          execute "SET search_path TO #{schema_csv}"
          @schema_search_path = schema_csv
        end
      end

      # Returns the active schema search path.
      def schema_search_path
        @schema_search_path ||= query('SHOW search_path')[0][0]
      end

      # Returns the current client message level.
      def client_min_messages
        query('SHOW client_min_messages')[0][0]
      end

      # Set the client message level.
      def client_min_messages=(level)
        execute("SET client_min_messages TO '#{level}'")
      end

      # Returns the sequence name for a table's primary key or some other specified key.
      def default_sequence_name(table_name, pk = nil) #:nodoc:
        default_pk, default_seq = pk_and_sequence_for(table_name)
        default_seq || "#{table_name}_#{pk || default_pk || 'id'}_seq"
      end

      # Resets the sequence of a table's primary key to the maximum value.
      def reset_pk_sequence!(table, pk = nil, sequence = nil) #:nodoc:
        unless pk and sequence
          default_pk, default_sequence = pk_and_sequence_for(table)
          pk ||= default_pk
          sequence ||= default_sequence
        end
        if pk
          if sequence
            quoted_sequence = quote_column_name(sequence)

            select_value <<-end_sql, 'Reset sequence'
              SELECT setval('#{quoted_sequence}', (SELECT COALESCE(MAX(#{quote_column_name pk})+(SELECT increment_by FROM #{quoted_sequence}), (SELECT min_value FROM #{quoted_sequence})) FROM #{quote_table_name(table)}), false)
            end_sql
          else
            @logger.warn "#{table} has primary key #{pk} with no default sequence" if @logger
          end
        end
      end

      # Returns a table's primary key and belonging sequence.
      def pk_and_sequence_for(table) #:nodoc:
        # First try looking for a sequence with a dependency on the
        # given table's primary key.
        result = query(<<-end_sql, 'PK and serial sequence')[0]
          SELECT attr.attname, seq.relname
          FROM pg_class      seq,
               pg_attribute  attr,
               pg_depend     dep,
               pg_namespace  name,
               pg_constraint cons
          WHERE seq.oid           = dep.objid
            AND seq.relkind       = 'S'
            AND attr.attrelid     = dep.refobjid
            AND attr.attnum       = dep.refobjsubid
            AND attr.attrelid     = cons.conrelid
            AND attr.attnum       = cons.conkey[1]
            AND cons.contype      = 'p'
            AND dep.refobjid      = '#{table}'::regclass
        end_sql

        if result.nil? or result.empty?
          # If that fails, try parsing the primary key's default value.
          # Support the 7.x and 8.0 nextval('foo'::text) as well as
          # the 8.1+ nextval('foo'::regclass).
          result = query(<<-end_sql, 'PK and custom sequence')[0]
            SELECT attr.attname,
              CASE
                WHEN split_part(def.adsrc, '''', 2) ~ '.' THEN
                  substr(split_part(def.adsrc, '''', 2),
                         strpos(split_part(def.adsrc, '''', 2), '.')+1)
                ELSE split_part(def.adsrc, '''', 2)
              END
            FROM pg_class       t
            JOIN pg_attribute   attr ON (t.oid = attrelid)
            JOIN pg_attrdef     def  ON (adrelid = attrelid AND adnum = attnum)
            JOIN pg_constraint  cons ON (conrelid = adrelid AND adnum = conkey[1])
            WHERE t.oid = '#{table}'::regclass
              AND cons.contype = 'p'
              AND def.adsrc ~* 'nextval'
          end_sql
        end

        # [primary_key, sequence]
        [result.first, result.last]
      rescue
        nil
      end

      # Renames a table.
      def rename_table(name, new_name)
        execute "ALTER TABLE #{quote_table_name(name)} RENAME TO #{quote_table_name(new_name)}"
      end

      # Adds a new column to the named table.
      # See TableDefinition#column for details of the options you can use.
      def add_column(table_name, column_name, type, options = {})
        default = options[:default]
        notnull = options[:null] == false

        # Add the column.
        execute("ALTER TABLE #{quote_table_name(table_name)} ADD COLUMN #{quote_column_name(column_name)} #{type_to_sql(type, options[:limit], options[:precision], options[:scale])}")

        change_column_default(table_name, column_name, default) if options_include_default?(options)
        change_column_null(table_name, column_name, false, default) if notnull
      end

      # Changes the column of a table.
      def change_column(table_name, column_name, type, options = {})
        quoted_table_name = quote_table_name(table_name)

        begin
          execute "ALTER TABLE #{quoted_table_name} ALTER COLUMN #{quote_column_name(column_name)} TYPE #{type_to_sql(type, options[:limit], options[:precision], options[:scale])}"
        rescue ActiveRecord::StatementInvalid
          # This is PostgreSQL 7.x, so we have to use a more arcane way of doing it.
          begin
            begin_db_transaction
            tmp_column_name = "#{column_name}_ar_tmp"
            add_column(table_name, tmp_column_name, type, options)
            execute "UPDATE #{quoted_table_name} SET #{quote_column_name(tmp_column_name)} = CAST(#{quote_column_name(column_name)} AS #{type_to_sql(type, options[:limit], options[:precision], options[:scale])})"
            remove_column(table_name, column_name)
            rename_column(table_name, tmp_column_name, column_name)
            commit_db_transaction
          rescue
            rollback_db_transaction
          end
        end

        change_column_default(table_name, column_name, options[:default]) if options_include_default?(options)
        change_column_null(table_name, column_name, options[:null], options[:default]) if options.key?(:null)
      end

      # Changes the default value of a table column.
      def change_column_default(table_name, column_name, default)
        execute "ALTER TABLE #{quote_table_name(table_name)} ALTER COLUMN #{quote_column_name(column_name)} SET DEFAULT #{quote(default)}"
      end

      def change_column_null(table_name, column_name, null, default = nil)
        unless null || default.nil?
          execute("UPDATE #{quote_table_name(table_name)} SET #{quote_column_name(column_name)}=#{quote(default)} WHERE #{quote_column_name(column_name)} IS NULL")
        end
        execute("ALTER TABLE #{quote_table_name(table_name)} ALTER #{quote_column_name(column_name)} #{null ? 'DROP' : 'SET'} NOT NULL")
      end

      # Renames a column in a table.
      def rename_column(table_name, column_name, new_column_name)
        execute "ALTER TABLE #{quote_table_name(table_name)} RENAME COLUMN #{quote_column_name(column_name)} TO #{quote_column_name(new_column_name)}"
      end

      # Drops an index from a table.
      def remove_index(table_name, options = {})
        execute "DROP INDEX #{index_name(table_name, options)}"
      end

      # Maps logical Rails types to PostgreSQL-specific data types.
      def type_to_sql(type, limit = nil, precision = nil, scale = nil)
        return super unless type.to_s == 'integer'

        case limit
          when 1..2;      'smallint'
          when 3..4, nil; 'integer'
          when 5..8;      'bigint'
          else raise(ActiveRecordError, "No integer type has byte size #{limit}. Use a numeric with precision 0 instead.")
        end
      end

      # Returns a SELECT DISTINCT clause for a given set of columns and a given ORDER BY clause.
      #
      # PostgreSQL requires the ORDER BY columns in the select list for distinct queries, and
      # requires that the ORDER BY include the distinct column.
      #
      #   distinct("posts.id", "posts.created_at desc")
      def distinct(columns, order_by) #:nodoc:
        return "DISTINCT #{columns}" if order_by.blank?

        # Construct a clean list of column names from the ORDER BY clause, removing
        # any ASC/DESC modifiers
        order_columns = order_by.split(',').collect { |s| s.split.first }
        order_columns.delete_if &:blank?
        order_columns = order_columns.zip((0...order_columns.size).to_a).map { |s,i| "#{s} AS alias_#{i}" }

        # Return a DISTINCT ON() clause that's distinct on the columns we want but includes
        # all the required columns for the ORDER BY to work properly.
        sql = "DISTINCT ON (#{columns}) #{columns}, "
        sql << order_columns * ', '
      end
      
      # Returns an ORDER BY clause for the passed order option.
      # 
      # PostgreSQL does not allow arbitrary ordering when using DISTINCT ON, so we work around this
      # by wrapping the +sql+ string as a sub-select and ordering in that query.
      def add_order_by_for_association_limiting!(sql, options) #:nodoc:
        return sql if options[:order].blank?
        
        order = options[:order].split(',').collect { |s| s.strip }.reject(&:blank?)
        order.map! { |s| 'DESC' if s =~ /\bdesc$/i }
        order = order.zip((0...order.size).to_a).map { |s,i| "id_list.alias_#{i} #{s}" }.join(', ')
        
        sql.replace "SELECT * FROM (#{sql}) AS id_list ORDER BY #{order}"
      end

      protected
        # Returns the version of the connected PostgreSQL version.
        def postgresql_version
          @postgresql_version ||=
            if @connection.respond_to?(:server_version)
              @connection.server_version
            else
              # Mimic PGconn.server_version behavior
              begin
                query('SELECT version()')[0][0] =~ /PostgreSQL (\d+)\.(\d+)\.(\d+)/
                ($1.to_i * 10000) + ($2.to_i * 100) + $3.to_i
              rescue
                0
              end
            end
        end

      private
        # The internal PostgreSQL identifier of the money data type.
        MONEY_COLUMN_TYPE_OID = 790 #:nodoc:
        BYTEA_COLUMN_TYPE_OID = 17 #:nodoc:
        # Connects to a PostgreSQL server and sets up the adapter depending on the
        # connected server's characteristics.
        def connect
          @connection = PGconn.connect(*@connection_parameters)
          PGconn.translate_results = false if PGconn.respond_to?(:translate_results=)

          # Ignore async_exec and async_query when using postgres-pr.
          @async = @config[:allow_concurrency] && @connection.respond_to?(:async_exec)

          # Use escape string syntax if available. We cannot do this lazily when encountering
          # the first string, because that could then break any transactions in progress.
          # See: http://www.postgresql.org/docs/current/static/runtime-config-compatible.html
          # If PostgreSQL doesn't know the standard_conforming_strings parameter then it doesn't
          # support escape string syntax. Don't override the inherited quoted_string_prefix.
          if supports_standard_conforming_strings?
            self.class.instance_eval do
              define_method(:quoted_string_prefix) { 'E' }
            end
          end

          # Money type has a fixed precision of 10 in PostgreSQL 8.2 and below, and as of
          # PostgreSQL 8.3 it has a fixed precision of 19. PostgreSQLColumn.extract_precision
          # should know about this but can't detect it there, so deal with it here.
          money_precision = (postgresql_version >= 80300) ? 19 : 10
          PostgreSQLColumn.module_eval(<<-end_eval)
            def extract_precision(sql_type)
              if sql_type =~ /^money$/
                #{money_precision}
              else
                super
              end
            end
          end_eval

          configure_connection
        end

        # Configures the encoding, verbosity, and schema search path of the connection.
        # This is called by #connect and should not be called manually.
        def configure_connection
          if @config[:encoding]
            if @connection.respond_to?(:set_client_encoding)
              @connection.set_client_encoding(@config[:encoding])
            else
              execute("SET client_encoding TO '#{@config[:encoding]}'")
            end
          end
          self.client_min_messages = @config[:min_messages] if @config[:min_messages]
          self.schema_search_path = @config[:schema_search_path] || @config[:schema_order]
        end

        # Returns the current ID of a table's sequence.
        def last_insert_id(table, sequence_name) #:nodoc:
          Integer(select_value("SELECT currval('#{sequence_name}')"))
        end

        # Executes a SELECT query and returns the results, performing any data type
        # conversions that are required to be performed here instead of in PostgreSQLColumn.
        def select(sql, name = nil)
          fields, rows = select_raw(sql, name)
          result = []
          for row in rows
            row_hash = {}
            fields.each_with_index do |f, i|
              row_hash[f] = row[i]
            end
            result << row_hash
          end
          result
        end

        def select_raw(sql, name = nil)
          res = execute(sql, name)
          results = result_as_array(res)
          fields = []
          rows = []
          if res.ntuples > 0
            fields = res.fields
            results.each do |row|
              hashed_row = {}
              row.each_index do |cell_index|
                # If this is a money type column and there are any currency symbols,
                # then strip them off. Indeed it would be prettier to do this in
                # PostgreSQLColumn.string_to_decimal but would break form input
                # fields that call value_before_type_cast.
                if res.ftype(cell_index) == MONEY_COLUMN_TYPE_OID
                  # Because money output is formatted according to the locale, there are two
                  # cases to consider (note the decimal separators):
                  #  (1) $12,345,678.12        
                  #  (2) $12.345.678,12
                  case column = row[cell_index]
                    when /^-?\D+[\d,]+\.\d{2}$/  # (1)
                      row[cell_index] = column.gsub(/[^-\d\.]/, '')
                    when /^-?\D+[\d\.]+,\d{2}$/  # (2)
                      row[cell_index] = column.gsub(/[^-\d,]/, '').sub(/,/, '.')
                  end
                elsif res.ftype(cell_index) == BYTEA_COLUMN_TYPE_OID
                  row[cell_index] = PGconn.unescape_bytea(row[cell_index])
                end

                hashed_row[fields[cell_index]] = column
              end
              rows << row
            end
          end
          res.clear
          return fields, rows
        end

        # Returns the list of a table's column names, data types, and default values.
        #
        # The underlying query is roughly:
        #  SELECT column.name, column.type, default.value
        #    FROM column LEFT JOIN default
        #      ON column.table_id = default.table_id
        #     AND column.num = default.column_num
        #   WHERE column.table_id = get_table_id('table_name')
        #     AND column.num > 0
        #     AND NOT column.is_dropped
        #   ORDER BY column.num
        #
        # If the table name is not prefixed with a schema, the database will
        # take the first match from the schema search path.
        #
        # Query implementation notes:
        #  - format_type includes the column size constraint, e.g. varchar(50)
        #  - ::regclass is a function that gives the id for a table name
        def column_definitions(table_name) #:nodoc:
          query <<-end_sql
            SELECT a.attname, format_type(a.atttypid, a.atttypmod), d.adsrc, a.attnotnull
              FROM pg_attribute a LEFT JOIN pg_attrdef d
                ON a.attrelid = d.adrelid AND a.attnum = d.adnum
             WHERE a.attrelid = '#{table_name}'::regclass
               AND a.attnum > 0 AND NOT a.attisdropped
             ORDER BY a.attnum
          end_sql
        end
    end
  end
end
