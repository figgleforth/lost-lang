module Ore
	class Scope
		attr_accessor :enclosing_scope, :sibling_scopes, :declarations, :name, :type_by_identifier, :static_declarations

		def initialize name = nil
			@name                = name
			@declarations        = {}
			@sibling_scopes      = []
			@type_by_identifier  = {}
			@static_declarations = Set.new
		end

		def declare identifier, value
			self[identifier] = value
		end

		# todo: Currently there is no clear rule on multiple unpacks. :double_unpack
		def get key
			key_str = key&.to_s

			return @declarations[key_str] if @declarations.key?(key_str) # note; calling #key? on @declarations here because I specifically want to see if this key is on @declarations.

			@sibling_scopes.reverse_each do |sibling|
				return sibling[key_str] if sibling.has? key_str # note; calling #has? here so the sibling can evaluate any siblings it might have
			end

			nil
		end

		def [] key
			get key
		end

		def []= key, value
			@declarations[key.to_s] = value
		end

		def is compare
			@name == compare
		end

		def has? identifier
			id_str = identifier.to_s

			# todo: Currently there is no clear rule on multiple unpacks. :double_unpack
			return true if @sibling_scopes.any? do |sibling|
				sibling.has? id_str
			end

			@declarations.key?(id_str) || @static_declarations.include?(id_str)
		end

		def delete key
			return nil unless key
			@declarations.delete(key.to_s)
		end

		def inspect
			filtered = instance_variables.reject { |v| v == :@enclosing_scope }
			vars     = filtered.map { |v| "#{v}=#{instance_variable_get(v).inspect}" }
			"#<#{self.class.name} #{vars.join(', ')}>"
		end

		def to_s
			"#<#{self.class.name} name=#{@name.inspect} declarations=#{@declarations.keys.inspect}>"
		end
	end

	class Global < Scope
	end

	class Temporary < Scope
	end

	class Type < Scope
		attr_accessor :expressions, :types, :routes

		def initialize name = nil
			super name
			@types = Set[name]
		end
	end

	class Instance < Type
		def initialize name = 'Instance'
			super name
		end

		# This is mostly for Array and Dictionary, so we can automatically forward [] and []= to the correct storage location. Their proxy_delegate is the object that ruby_proxies uses to forward calls to already anyway
		def []= key, value
			delegate_name = self.class.respond_to?(:proxy_delegate_name) && self.class.proxy_delegate_name

			if delegate_name && key.to_s == delegate_name
				delegate_value = value.respond_to?(key) ? value.send(key) : value
				send "#{key}=", delegate_value
				@declarations[key.to_s] = delegate_value
			else
				super
			end
		end
	end

	class Func < Scope
		attr_accessor :expressions, :arguments, :return_type, :param_types
	end

	class Route < Func
		attr_accessor :http_method, :path, :handler, :parts, :param_names
	end

	class Nil < Scope # Like Ruby's NilClass, this represents the absence of a value.
		NIL = new()

		def self.shared
			NIL
		end

		private_class_method :new # prevent external instantiation

		def initialize
			super 'nil'
		end
	end

	class Bool < Instance
		TRUE  = new(true)
		FALSE = new(false)

		attr_accessor :truthiness

		def !
			!@truthiness
		end

		def self.truthy
			TRUE
		end

		def self.falsy
			FALSE
		end

		# private_class_method :new # prevent external instantiation

		def initialize truthiness = true
			super((!!truthiness).to_s.capitalize) # Scope class only needs @name
			@truthiness = !!truthiness
		end
	end

	class Range < ::Range
	end

	class Server < Instance
		DEFAULT_PORT = 8080
		attr_accessor :server_instance, :port, :routes, :webrick_server, :server_thread
	end

	class Request < Scope
		def initialize
			super 'Request'
		end
	end

	class Response < Scope
		attr_accessor :webrick_response
	end

end
