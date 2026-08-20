module Lost
	# Represents a set of declarations which make up an object (including dictionaries and their keys)
	#
	#   name, type, value
	#
	# <TypeA, b: TypeB, c := "xyz">
	class Struct < Instance
		attr_accessor :names, :values, :type_names, :members

		def initialize names = [], type_names = [], types = [], values = []
			super 'Struct'

			@names      = names
			@type_names = type_names
			@values     = values

			# Only ever set for a bare named struct (`Named <Struct>`, see #interp_type) -- nil for every other construction path, including the plain `<...>`/`ANY_IDENT := <struct>` forms, which stay anonymous (reachable only through whatever variable holds them).
			declare 'name', nil
			declare 'names', Lost::Array.new(names), 'Array'
			declare 'values', Lost::Array.new(values), 'Array'
			declare 'type_names', Lost::Array.new(type_names), 'Array'
			declare 'types', Lost::Array.new(types), 'Array'

			names.each_with_index do |name, i|
				next unless name
				declare name, (values[i].nil? ? types[i] : values[i]), type_names[i]
			end
		end

		# Per-member resolved type *objects* (Type instances for named/typed members, or the raw
		# interpreted value for unnamed members) -- exposed to Lost as `.types`. Distinct from the
		# inherited `.types` (Type#types, this Struct instance's own composed-type Set, unrelated --
		# see Interpreter#build_struct's `struct.types = struct_type.types`), which is why this reads
		# off `@declarations` under its own name instead of being a plain attr_accessor called `types`.
		def type_objects
			@declarations['types'].values
		end

		# Strict equality for declaration-time collision checks (does a variant with this *exact*
		# structure already exist under this base name, so a new `Type<Struct>{}` should extend it
		# rather than start a fresh variant?). Two declarations only ever describe the *same*
		# variant if every member's name and type match -- a differently-named member of the same
		# type (`dict:`/`other:`, both `Dictionary`) is a distinct variant, which is the whole point
		# of comparing `names` here too.
		#
		# Order-insensitive once every member is named -- a name (not position) is what identifies a
		# named member everywhere it's actually used (dot access, named construction), so `<a: X, b:
		# Y>` and `<b: Y, a: X>` are the same declaration, just typed in a different order. Falls back
		# to strict positional comparison the moment either side has an unnamed member, where position
		# *is* the member's only identity (positional construction binds by index).
		def structure_declaration_equal? other
			return false unless other.is_a? Struct
			return names == other.names && type_names == other.type_names unless names.all? && other.names.all?

			names.zip(type_names).sort == other.names.zip(other.type_names).sort
		end

		# Loose/compositional match for reference resolution (`Abc<value>()` against a declared
		# `Abc<dict: Dictionary>{}`) -- same set-comparison rules as `=>=` (superset): each supplied
		# value's own candidate type set (its own name plus everything it composes -- computed by the
		# caller via #Interpreter#member_candidate_type_names and passed in here, positionally) must
		# include what this struct declared for that member. A reference never supplies member names
		# (`Woof<'hello', 4815>`, never `Woof<key: 'hello'>`), so only `type_names` is compared here,
		# never `names`.
		def satisfied_by_candidates? candidate_type_lists
			return false unless candidate_type_lists.length == type_names.length

			type_names.each_with_index.all? { |declared_type, i| candidate_type_lists[i].include? declared_type }
		end
	end
end
