@load 'lost/database'
@load 'lost/table'

Task_Type [TODO, BUG, DESIGN]

Task <
	type: Task_Type
	done := false
	text: String
	id: Primary_Key
>

db := @connect Sqlite.memory()

Table_With_Name_And_Schema := Table\<String, Struct> { # tagged type
	new (args;)
	stuff (a, b, c;)
}

Tasks | Table\<'tasks', Task> {
	new (db: Database;
		Self.table_name = 'tasks'
		self.database = db
		self.tag.0 # 'tasks'
	)

	Self.create (data: Task -> Task;
		@ruby
	)
}

tasks := Tasks(db)

data1 := <type := Task_Type.DESIGN, done := false, text := "Finish database syntax"> # anon struct
data2 := Task(Task_Type.TODO, false, "Another way of instantiating the data")        # named struct

task1: Task = tasks.create(data1)
task2: Task = tasks.create(data2)
@puts task1
@puts task2




###
@puts tasks.name
@puts tasks.types
@puts tasks.table_name
@puts tasks.schema
@puts tasks.database.connection
@puts "task: `task`"
###

### Vision
# 1: Create a struct representing your table columns and name (by name Task)
Todo := <text: String, done: Bool, id: Primary_Key>

## 2: Create a Table class representing the Task columns struct
Table\<name: String, columns: Struct> {}     # default Table provided by Lost
Table\<columns: Struct> {}                   # shorthand with named struct whose name can be used to derive table name

Todos | Table\<'todos', Todo> {}       # declares table with explicit name
Todos | Table\<Todo> {}                # declares table with inferred name from Todo struct
###

#Tasks\Connection {
##	new {;
##		self.tag.db
##	}
#}
#
#Tasks\<db: Database> {
##	self.tag.db
#}
#
#Tasks\<Connection> {
##	self.tag.db
#}
