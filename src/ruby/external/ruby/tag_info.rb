module Ore
	# Instance, not Scope — the enclosing_scope method-lookup fallback used for arr.push(...)-style calls (see #interp_identifier) is gated on `scope.is_a?(Ore::Instance)`, which Tags needs too for ore/tags.ore's declarations (==, include?) to actually be reachable.
	class Tag_Info < Instance # ore/tags.ore
		attr_accessor :types # note; This shadows the existing @types that comes from Ore::Type. They both have the same function, but this will be nice documentation for later.
		attr_accessor :names # names[i] is nil for unnamed slots
		attr_accessor :defaults # {name => interpreted default value}, only for named slots that declared one

		def initialize values = [], names = [], defaults = {}
			super 'Tags'
			@types                 = values
			@names                 = names
			@defaults              = defaults
			@declarations['types'] = Ore::Array.new values # so `.tags.types.first()`/`[0]`/`.0`etc. work from Ore code

			names.each_with_index do |name, i|
				@declarations[name.to_s] = values[i] if name
			end
		end

		# note; equality is handled in Ore
		# note; include?{;} is handled in Ore
	end
end
