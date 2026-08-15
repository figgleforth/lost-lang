module Ore
	class Number < Instance
		extend Ruby_Proxies
		attr_accessor :numerator, :denominator, :type

		# Mirrors String/Array/Dictionary's own initialize: sync both the Ruby attr (read by the arithmetic methods below via plain Ruby dispatch) and @declarations (read by Ore-level dot access, e.g. `123.numerator`) -- a bare attr_accessor write alone only reaches the former.
		def initialize numerator = 0, denominator = 1, type = nil
			super 'Number'
			@numerator                    = numerator
			@denominator                  = denominator
			@type                         = type
			@declarations['numerator']    = numerator
			@declarations['denominator']  = denominator
			@declarations['type']         = type
		end

		def + other
			numerator + other.numerator
		end

		def - other
			numerator - other.numerator
		end

		def * other
			numerator * other.numerator
		end

		def ** other
			numerator ** other.numerator
		end

		def / other
			numerator / other.numerator
		end

		def % other
			numerator % other.numerator
		end

		def >> other
			numerator >> other.numerator
		end

		def << other
			numerator << other.numerator
		end

		def ^ other
			numerator ^ other.numerator
		end

		def & other
			numerator & other.numerator
		end

		def | other
			numerator | other.numerator
		end

		proxy_delegate 'numerator'
		proxy :to_s
		proxy :abs
		proxy :floor
		proxy :ceil
		proxy :round
		proxy :even?
		proxy :odd?
		proxy :to_i
		proxy :to_f
		proxy :clamp

		def proxy_sqrt
			Math.sqrt numerator
		end

		def proxy_rand max
			max_val = max.respond_to?(:numerator) ? max.numerator : max.to_i
			::Kernel.rand(max_val + 1)
		end
	end
end