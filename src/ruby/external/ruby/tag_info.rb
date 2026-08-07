module Ore
	class Tag_Info < Instance # ore/tag_info.ore

		attr_accessor :names # names[i] is nil for unnamed slots
		attr_accessor :defaults # {name => interpreted default value}, only for named slots that declared one

		def initialize values = [], names = [], defaults = {}
			super 'Tags'
			@names                  = names
			@defaults               = defaults
			@declarations['types'] = Ore::Array.new values # so `.tags.types.first()`/`[0]`/`.0`etc. work from Ore code

			names.each_with_index do |name, i|
				@declarations[name.to_s] = values[i] if name
			end
		end
		
		def tag_types
			@declarations['types'].values
		end

		# note; equality is handled in Ore
		# note; include?{;} is handled in Ore
	end
end
