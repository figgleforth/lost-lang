module Ore
	# name: String
	# type: Any
	# value: Any
	class Field < Instance
		attr_accessor :name, :type, :value

		def initialize name = nil, type = nil, value = nil
			super 'Field'
			@name  = name
			@type  = type
			@value = value

			@declarations['name']  = name
			@declarations['type']  = type
			@declarations['value'] = value
		end
	end
end
