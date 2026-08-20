### Introduction

Number literals (integers and floats alike) are all backed by `Lost::Number`. `abs` returns the absolute value.
###
days_off_course := -8
@assert days_off_course.abs() == 8, 'abs should return the absolute value'


### floor, ceil, round

###
@assert 4.2.floor() == 4, 'floor should round down'
@assert 4.2.ceil() == 5, 'ceil should round up'
@assert 4.5.round() == 5, 'round should round to nearest'


### sqrt, even?, odd?

###
@assert 16.sqrt() == 4.0, 'sqrt should return the square root'
@assert 108.even?() == true, 'even? should be true for an even number'
@assert 108.odd?() == false, 'odd? should be false for an even number'


### to_s and clamp

`to_s` converts a Number to a String -- note it prints the same either way through `@puts`, since a String's own display is unquoted.
###
@assert 42.to_s() == '42', 'to_s should convert a Number to a String'
@assert 150.clamp(0, 100) == 100, 'clamp should pull a value above the max down to it'
@assert (-5).clamp(0, 100) == 0, 'clamp should push a value below the min up to it'
