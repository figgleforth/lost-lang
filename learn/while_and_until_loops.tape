### Introduction

`while` loops as long as its condition holds. The castaways are rationing a bottle of water -- keep drinking while there's still some left:
###
water := 5
while water > 0
	water -= 1
end
@assert water == 0, 'while should keep looping until the condition goes false'


### until: the inverse

`until` reads as "loop until this becomes true" -- exactly `while !condition`, spelled whichever way is clearer at the call site. Sayid keeps trying the signal flare until he's fired it three times:
###
flares_fired := 0
until flares_fired == 3
	flares_fired += 1
end
@assert flares_fired == 3, 'until should keep looping until the condition becomes true'


### Both are expressions

A loop's value is whatever its body last evaluated to -- there's no need for a separate accumulator variable outside it. If the condition is false from the very start, the loop never runs and the whole expression is `nil`:
###
x := 0
last_seen := while x < 3
	x += 1
end
@assert last_seen == 3, "a loop's value should be whatever its body last evaluated to"

never_ran := while false
	1
end
@assert never_ran == nil, 'a loop that never runs should evaluate to nil'


### Chaining with elwhile

`elwhile` chains another loop once the prior one's condition goes false, the same way `elif` chains conditionals. Hurley counts numbers while he's below 4, then Charlie counts down while he's above -8:
###
hurley_count := 0
charlie_count := 0
while hurley_count < 4
	hurley_count += 1
elwhile charlie_count > -8
	charlie_count -= 1
end
@assert hurley_count == 4, 'the first loop in the chain should run to completion'
@assert charlie_count == -8, 'elwhile should pick up once the prior condition goes false'


### else always runs last

`else`, if present, always evaluates after the while/elwhile chain finishes -- regardless of whether any loop in the chain ever ran -- and its value becomes the whole expression's result, overriding whatever the loop bodies produced. That's completely optional though.
###
x2 := 0
result := while x2 < 4
	x2 += 1
else
	'done rationing'
end
@assert result == 'done rationing', "else's value should override the loop body's, even though the while loop ran to completion"

x2 := 0
result := while x2 < 4
	x2 += 1
end
@assert result == 4, "without else, the loop's own last value should be the result"
