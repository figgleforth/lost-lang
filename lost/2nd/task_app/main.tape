@load 'lost/database'
@load 'lost/table'

db := Sqlite.memory()
connected_db := @connect db # @connect just returns the database you gave it. todo; Connection {} or <>
@assert connected_db == db

Task_Type :: { TODO, BUG, DESIGN } # Task_Type [ TODO BUG DESIGN ] may be better for easy identification

Task <id: Primary_Key, type: Task_Type = Task_Type.TODO, text: String, done := false>
@assert Task.name == 'Task'

Table<name: String, columns: Struct> {
	new { database: Database = ~/db;
		# todo; this should all be abstracted away, done internally by Lost
		self.database = database
		self.schema = structure.columns
		database.create_table(structure.name, structure.columns)
	}
}

Tasks | Table<'tasks', Task> {
	# returns Task structs as row data
	# todo; this should also be automatic
	Self.database = db
	Self.table_name = 'tasks'
}

tasks := Tasks()
@assert tasks

task: Task = Tasks.create(<type := Task_Type.DESIGN, done := false, text := "Finish database syntax">)
@assert task
@puts task






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
Table<name: String, columns: Struct> {}     # default Table provided by Lost
Table<columns: Struct> {}                   # shorthand with named struct whose name can be used to derive table name

Todos | Table<'todos', Todo> {}       # declares table with explicit name
Todos | Table<Todo> {}                # declares table with inferred name from Todo struct
###
