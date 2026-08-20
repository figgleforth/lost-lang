Table {
	database: Database
	schema: Struct
	table_name: String

	infer_table_name_from_class! {; @ruby }

	Self.all {; @ruby }
	Self.find { id; @ruby }
	Self.find_by { dict; @ruby }
	Self.where { dict; @ruby }
	Self.create { dict_or_struct; @ruby }
	Self.update { id, dict; @ruby }
	Self.delete { id; @ruby }

###
	@operator -> @infix { left,right; left has_one right }
	@operator ->> @infix { left,right; left has_many right }
	@operator <- @infix { left,right; right belongs_to left }

	User -> Profile     # user has_one profile
	User ->> Post       # user has_many profiles
	Post <- User        # user belongs_to post
###
}
