require 'minitest/autorun'

class Base_Test < Minitest::Test
	# note; `rescue *exceptions` with an empty `exceptions` (the default, when called with no explicit class) rescues nothing at all -- not the same as a bare `rescue`, which defaults to StandardError. `refute_raises do ... end` (no args) was silently a no-op everywhere it was already used this way (database_test.rb, parser_test.rb): "passing" only because the code inside genuinely didn't raise, not because anything was actually being caught.
	def refute_raises * exceptions
		exceptions = [StandardError] if exceptions.empty?
		yield
	rescue *exceptions => e
		flunk "Expected no exception, but got #{e.class}: #{e.message}"
	end
end
