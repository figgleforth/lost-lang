module Ore
	class Func_Signature # Does not need to be a scope
		attr_accessor :param_types, :return_type

		def initialize param_types = [], return_type = nil
			@param_types = param_types
			@return_type = return_type
		end
	end
end
