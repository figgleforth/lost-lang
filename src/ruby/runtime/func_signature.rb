module Ore
	class Func_Signature # Does not need to be a scope
		attr_accessor :param_types, :return_type

		def initialize param_types = [], return_type = nil
			@param_types = param_types
			@return_type = return_type
		end

		# @param func [#param_types, #return_type] a real Ore::Func or another Func_Signature
		def matches? other
			case other
			when Func_Signature
				other.param_types == param_types && other.return_type == return_type
			when Func
				other.func_signature.param_types == param_types && other.func_signature.return_type == return_type
			else
				false
			end
		end

		def to_s
			"{#{param_types.join(',')} -> #{return_type};}"
		end
	end
end
