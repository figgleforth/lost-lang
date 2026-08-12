module Ore
	# Represents a set of declarations which make up an object (including dictionaries and their keys)
	#
	#   name, type, value
	#
	# <TypeA, b: TypeB, c := "xyz">
	class Struct < Instance
		attr_accessor :names, :values, :type_names

		def initialize names = [], type_names = [], types = [], values = []
			super 'Struct'

			@names      = names
			@type_names = type_names
			@values     = values

			declare 'names', Ore::Array.new(names), 'Array'
			declare 'values', Ore::Array.new(values), 'Array'
			declare 'type_names', Ore::Array.new(type_names), 'Array'
			declare 'types', Ore::Array.new(types), 'Array'

			names.each_with_index do |name, i|
				next unless name
				declare name, (values[i].nil? ? types[i] : values[i]), type_names[i]
			end
		end

		# Per-member resolved type *objects* (Type instances for named/typed members, or the raw
		# interpreted value for unnamed members) -- exposed to Ore as `.types`. Distinct from the
		# inherited `.types` (Type#types, this Struct instance's own composed-type Set, unrelated --
		# see Interpreter#build_struct's `struct.types = struct_type.types`), which is why this reads
		# off `@declarations` under its own name instead of being a plain attr_accessor called `types`.
		def type_objects
			@declarations['types'].values
		end

		# Strict equality for declaration-time collision checks (does a variant with this *exact*
		# structure already exist under this base name, so a new `Type<Struct>{}` should extend it
		# rather than start a fresh variant?) -- same set-comparison rules as the language's own
		# `===` operator on Type/Instance (interp_infix's COMPARISON_OPERATORS branch): plain,
		# positional `==` on the underlying arrays, nothing looser. Two declarations only ever
		# describe the *same* variant if every member's name and type match exactly -- a
		# differently-named member of the same type (`dict:`/`other:`, both `Dictionary`) is a
		# distinct variant, which is the whole point of comparing `names` here too.
		def structure_declaration_equal? other
			other.is_a?(Struct) && names == other.names && type_names == other.type_names
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
