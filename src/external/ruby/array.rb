module Ore
	# note: Be sure to prefix with Ore:: whenever referencing this Array type to prevent ambiguity with Ruby's ::Array!
	class Array < Instance
		extend Ruby_Proxies
		attr_accessor :values

		def initialize values = []
			super 'Array'
			@values                 = values || []
			@declarations['values'] = @values
			::Array
		end

		proxy_delegate 'values'
		proxy :push
		proxy :pop
		proxy :shift
		proxy :unshift, as: :prepend # ore/array.ore's `unshift{;}` was renamed to `prepend{;}` (unshift is now just an alias, see #Interpreter#interp_directive's `@ruby` lookup, which resolves by the func's own declared name -- "prepend" -- not whatever alias it was called through)
		proxy :length
		proxy :length, as: :count
		proxy :first
		proxy :last
		proxy :slice
		proxy :reverse
		proxy :join
		proxy :sort
		proxy :uniq
		proxy :empty?

		# note; To prevent Scope#[] or Scope#get from missing out on the actual location of the array elements. Standard members still call through to [] and get. I'm manually calling these proxy methods in some places.
		def proxy_get index
			values[index]
		end

		def proxy_set index, value
			values[index] = value
		end

		def proxy_random
			values.sample
		end

		def proxy_concat other_array
			values.concat other_array.values
		end

		def proxy_flatten depth = -1
			ruby_array = values.map { |v| v.is_a?(Ore::Array) ? v.values : v }
			Ore::Array.new ruby_array.flatten depth
		end

		def == other
			# I think there's more to this than a simple evaluation. Tbd...
			values == other&.values
		end

		def + other
			Ore::Array.new(values + other.values)
		end
	end

	class Tuple < Ore::Array
		def initialize values = []
			super values
		end

		def inspect
			"(#{values.map(&:inspect).join(', ')})"
		end
	end
end
