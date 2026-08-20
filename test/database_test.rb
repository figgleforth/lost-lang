require 'minitest/autorun'
require_relative '../src/ore'
require_relative 'base_test'
require 'net/http'
require 'uri'
require 'sequel'
require 'securerandom'

class Database_Test < Base_Test
	DATABASE = "@load 'ore/database.ore'"
	RECORD   = "@load 'ore/table.ore'"

	def before_setup
		@filepath = "./temp#{SecureRandom.hex}.db"
		File.delete(@filepath) if File.exist? @filepath
	end

	def after_teardown
		File.delete(@filepath) if File.exist? @filepath
	end

	def test_database_instance
		out = Ore.interp <<~ORE
		    #{DATABASE}
			db := Database()
		    sq := Sqlite('#{@filepath}')
			(db, sq)
		ORE
		assert_instance_of Ore::Database, out.values.first
		assert_instance_of Ore::Database, out.values.last

		assert_nil out.values.first.get 'adapter'
		assert_nil out.values.first.get 'url'
		assert_nil out.values.first.get 'connection'
		assert_nil out.values.last.get 'connection'

		# These are set in Sqlite.new{;}
		refute_nil out.values.last.get 'adapter'
		refute_nil out.values.last.get 'url'
	end

	def test_database_connection_instance
		out = Ore.interp <<~ORE
		    #{DATABASE}
		    db := Sqlite('#{@filepath}')
		    @connect db
			db.connection
		ORE
		refute_nil out
		assert_instance_of Sequel::SQLite::Database, out
	end

	def test_database_connection_is_cached
		out = Ore.interp <<~ORE
		    #{DATABASE}
		    db := Sqlite('#{@filepath}')
		    c1 := @connect db
		    c2 := @connect db
		    (c1, c2)
		ORE
		assert_equal out.values[0].object_id, out.values[1].object_id
	end

	def test_inferring_record_table_name
		out = Ore.interp <<~ORE
		    #{RECORD}
			r := Table()
			r.table_name

			Thing | Table {}
			t := Thing()
			t.infer_table_name_from_class!()
			(r, t)
		ORE
		assert_nil out.values.first.get 'table_name'
		assert_equal 'things', out.values.last.get('table_name')
	end

	def test_connect_directive_creates_database_connection
		out = Ore.interp <<~ORE
		    #{DATABASE}
		    db := Sqlite('#{@filepath}')
			db.connection
		ORE
		assert_nil out

		out = Ore.interp <<~ORE
		    #{DATABASE}
		    db := Sqlite('#{@filepath}')
			@connect db
			db.connection
		ORE
		assert_instance_of Sequel::SQLite::Database, out
	end

	def test_creating_table
		out = Ore.interp <<~ORE
		    #{DATABASE}
		    db := Sqlite('#{@filepath}')
			@connect db

			Users_Schema <id: Primary_Key>

			pre_tables := db.tables()
			db.create_table('users', Users_Schema)
			post_tables := db.tables()

			(pre_tables, post_tables)
		ORE
		assert_equal [[], [:users]], out.values.map { |ore_array| ore_array.get('values') }
	end

	def test_record_database_reference
		out = Ore.interp <<~ORE
		    #{DATABASE}, #{RECORD}
		    db := @connect Sqlite('#{@filepath}')

			Users_Schema <
				id: Primary_Key
				name: String
			>
			db.create_table('users', Users_Schema)

			User | Table {
				Self.database := db
				table_name := 'users'
			}

			none := User.all()
			cooper := User.create({name: 'Cooper'})

			luna := User.create({name: 'Luna'})

			users := User.all()
			(none, users, cooper, luna, db.table_exists?('users'))
		ORE
		assert_equal 0, out.values[0].values.count
		assert_equal 2, out.values[1].values.count
		assert_equal [{ id: 1, name: 'Cooper' }, { id: 2, name: 'Luna' }], out.values[1].values.map(&:hash)
		assert_equal({ id: 1, name: 'Cooper' }, out.values[2].hash)
		assert_equal({ id: 2, name: 'Luna' }, out.values[3].hash)
		assert out.values.last
	end

	def test_create_table_column_types
		refute_raises do
			Ore.interp <<~ORE
			    #{DATABASE}
			    db := @connect Sqlite('#{@filepath}')

				Things_Schema <
					id: Primary_Key
					label: String
					count: Int
					active: Bool
				>
				db.create_table('things', Things_Schema)
			ORE
		end
	end

	def test_record_update
		out = Ore.interp <<~ORE
		    #{DATABASE}, #{RECORD}
		    db := @connect Sqlite('#{@filepath}')

			Users_Schema <
				id: Primary_Key
				name: String
			>
			db.create_table('users', Users_Schema)

			User | Table {
				Self.database := db
				table_name := 'users'
			}

			created := User.create({name: 'Cooper'})
			User.update(created.id, {name: 'Cooper Updated'})
			User.find(created.id)
		ORE
		assert_equal 'Cooper Updated', out.hash[:name]
	end

	def test_record_find_by
		out = Ore.interp <<~ORE
		    #{DATABASE}, #{RECORD}
		    db := @connect Sqlite('#{@filepath}')

			Users_Schema <
				id: Primary_Key
				name: String
			>
			db.create_table('users', Users_Schema)

			User | Table {
				Self.database := db
				table_name := 'users'
			}

			User.create({name: 'Cooper'})
			User.create({name: 'Luna'})
			User.find_by({name: 'Luna'})
		ORE
		assert_equal({ id: 2, name: 'Luna' }, out.hash)
	end

	def test_record_find_by_returns_nil_when_not_found
		out = Ore.interp <<~ORE
		    #{DATABASE}, #{RECORD}
		    db := @connect Sqlite('#{@filepath}')

			Users_Schema <
				id: Primary_Key
				name: String
			>
			db.create_table('users', Users_Schema)

			User | Table {
				Self.database := db
				table_name := 'users'
			}

			User.find_by({name: 'nobody'})
		ORE
		assert_nil out
	end

	def test_record_where
		out = Ore.interp <<~ORE
		    #{DATABASE}, #{RECORD}
		    db := @connect Sqlite('#{@filepath}')

			Items_Schema <
				id: Primary_Key
				name: String
				kind: String
			>
			db.create_table('items', Items_Schema)

			Item | Table {
				Self.database := db
				table_name := 'items'
			}

			Item.create({name: 'Apple', kind: 'fruit'})
			Item.create({name: 'Banana', kind: 'fruit'})
			Item.create({name: 'Carrot', kind: 'vegetable'})

			Item.where({kind: 'fruit'})
		ORE
		assert_equal 2, out.values.count
		assert_equal ['Apple', 'Banana'], out.values.map { |d| d.hash[:name] }
	end

	def test_number_rand
		100.times do
			out = Ore.interp 'Number.rand(10)'
			assert_includes 0..10, out
		end
	end

	def test_number_rand_zero
		out = Ore.interp 'Number.rand(0)'
		assert_equal 0, out
	end
end
