module Ore
	class Func_Signature # Does not need to be a scope
		attr_accessor :param_types, :return_type

		def initialize param_types = [], return_type = nil
			@param_types = param_types
			@return_type = return_type
		end

		# @param func [#param_types, #return_type] a real Ore::Func or another Func_Signature
		def matches? func
			return false unless func.respond_to?(:param_types) && func.respond_to?(:return_type)
			func.param_types == param_types && func.return_type == return_type
		end

		def to_s
			"{#{param_types.join(',')} -> #{return_type};}"
		end
	end
end
