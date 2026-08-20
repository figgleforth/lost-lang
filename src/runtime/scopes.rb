module Lost
	class Scope
		attr_accessor :enclosing_scope, :readable_scopes, :writable_scopes, :declarations, :name, :type_by_identifier, :static_declarations, :structured_type_variants

		def initialize name = nil
			@name               = name
			@declarations       = {}
			@type_by_identifier = {}
			# WeakMaps, not Sets: membership here must not keep an instance alive on its own -- otherwise @add_readable_scope/@add_writable_scope (and the @readable/@writable param shorthand) would pin whatever's added for as long as the *containing* scope lives, even after every other reference to it is gone. Storing each entry as its own key AND value (wm[x] = x) is just how you use a WeakMap as a weak set -- there's no dedicated weak-Set in the stdlib.
			# Insertion order still matters here (most-recently-added wins on a name collision, like a stack -- see test_multiple_unpacks), so lookups below deliberately reverse .keys before searching. Ruby doesn't document WeakMap's iteration order the way it does Hash/Set's, but it matches insertion order in every version this has been tested against.
			@readable_scopes     = ObjectSpace::WeakMap.new
			@writable_scopes     = ObjectSpace::WeakMap.new
			@static_declarations = Set.new
			# `Type<Struct> { }` declarations of the same base name (e.g. every structured variant of "String") are kept here, separate from @declarations -- see #Interpreter#interp_structured_type_declaration/#find_structured_type_variant. A base name maps to every variant declared under it in this scope; matching is by real structure equality (names + types), not a mangled string key.
			@structured_type_variants = Hash.new { |h, k| h[k] = [] }
		end

		def declare identifier, value, type = nil
			self[identifier]                = value
			@type_by_identifier[identifier] = type if type
			value
		end

		# todo: Currently there is no clear rule on multiple unpacks. :double_unpack
		# note; Lookup order goes @declarations, @writable_scopes, @readable_scopes
		def get key
			key_str = key&.to_s

			return @declarations[key_str] if @declarations.key?(key_str) # note; calling #key? on @declarations here because I specifically want to see if this key is on @declarations.

			scope = @writable_scopes.keys.reverse_each.find { it.has? key_str }
			return scope[key_str] if scope

			scope = @readable_scopes.keys.reverse_each.find { it.has? key_str }
			return scope[key_str] if scope

			nil
		end

		def []= key, value
			key_str = key&.to_s

			return @declarations[key_str] = value if @declarations.key?(key_str)

			existing_writable = @writable_scopes.keys.reverse_each.find { it.has? key_str }
			return existing_writable.declarations[key_str] = value if existing_writable

			@declarations[key_str] = value
		end

		def [] key
			get key
		end

		def is compare
			@name == compare
		end

		# todo: Currently there is no clear rule on multiple unpacks. :double_unpack
		def has? identifier
			id_str = identifier.to_s

			return true if @writable_scopes.keys.any? do |sibling|
				sibling.has? id_str
			end

			return true if @readable_scopes.keys.any? do |sibling|
				sibling.has? id_str
			end

			@declarations.key?(id_str) || @static_declarations.include?(id_str)
		end

		def delete key
			return nil unless key
			key_str = key&.to_s

			return @declarations.delete(key_str) if @declarations.key?(key_str)

			existing_writable = @writable_scopes.keys.reverse_each.find { it.has? key_str }
			return existing_writable.declarations.delete(key_str) if existing_writable

			@declarations.delete key_str
		end

		def add_readable_scope scope
			return nil unless scope # todo; should this be an error?

			@readable_scopes[scope] = scope
		end

		def add_writable_scope scope
			return nil unless scope

			@writable_scopes[scope] = scope
		end

		def remove_readable_scope scope
			@readable_scopes.delete scope
		end

		def remove_writable_scope scope
			@writable_scopes.delete scope
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
		# Holds an Lost::Struct, exposed to Lost code as `.structure` (see #declare_structure) -- `structure_instance` is just the Ruby-side name.
		attr_accessor :structure_instance
		# A type's own struct declaration (e.g. `Abc<dict: Dictionary = {}> {}`)'s named/positional members, annotations, and defaults -- kept separate from `.structure`, which is only ever set on an explicit `Abc<...>` reference, never the bare type (see #interp_type_call).
		# Both live on Type, not Scope, since a structured reference is a dup of the type (same class), so Type/Instance can't stand in for this distinction.
		attr_accessor :structure_declaration
		# True only while this type's own body is being walked for the first time (#finish_type_declaration) -- the window during which `../member := value` may self-declare a brand-new static member, mirroring Instance's `has?('new')` check for the same rule on instance members.
		attr_accessor :declaration_in_progress

		def initialize name = nil
			super name
			@types                = Set[name]
			@declarations['name'] = name
			@static_declarations.add 'name' # So that Type.name works
			@declaration_in_progress = false
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
		attr_accessor :expressions, :parameters, :arguments, :func_signature
	end

	class Route < Func
		attr_accessor :http_method, :path, :handler, :parts, :param_names
	end

	class Any < Scope
		ANY = new()

		def self.shared
			ANY
		end

		private_class_method :new

		def initialize
			super 'Any'
		end
	end

	class Nil < Instance # Like Ruby's NilClass, this represents the absence of a value.
		NIL = new('Nil')

		def self.shared
			NIL
		end

		private_class_method :new # prevent external instantiation
	end

	class Bool < Instance
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
			@truthiness                 = !!truthiness
			@declarations['truthiness'] = @truthiness
		end

		TRUE  = new(true)
		FALSE = new(false)
	end

	class Range < ::Range
		def has? _identifier
			false
		end
	end

	class Server < Instance
		DEFAULT_PORT = 8080
		attr_accessor :port, :routes, :webrick_server, :server_thread
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
