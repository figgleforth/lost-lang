### Introduction

A verb after the collection turns `for` into a transformation that returns a value, instead of just running side effects. `map` transforms every element:
###
supplies := [1, 2, 3, 4, 5]
doubled := for supplies map
	it * 2
end
@assert doubled == [2, 4, 6, 8, 10], 'map should collect each transformed element'


### select and reject

`select` keeps elements where the body is truthy, `reject` keeps elements where it's falsy -- mirror images of each other. Splitting the survivors into two search parties by even/odd number:
###
group_a := for supplies select
	it % 2 == 0
end
@assert group_a == [2, 4], 'select should keep only the truthy elements'

group_b := for supplies reject
	it % 2 == 0
end
@assert group_b == [1, 3, 5], 'reject should keep only the falsy elements'


### count

`count` returns a plain number -- how many elements the body was truthy for, nothing collected:
###
even_count := for supplies count
	it % 2 == 0
end
@assert even_count == 2, 'count should tally the truthy elements'


### Verbs combine with stride

`by N` still groups into chunks first; the verb then runs once per chunk, same as a plain `for` would:
###
paired_sums := for [1, 2, 3, 4, 5, 6] map by 2
	it.0 + it.1
end
@assert paired_sums == [3, 7, 11], 'map with stride should run once per chunk'


### stop returns partial results

`stop` still breaks out of the loop early, but for `map`/`select`/`reject` the elements collected so far are kept instead of discarded -- Charlie stops counting driftwood the moment he spots a plane part:
###
driftwood := for [1, 2, 3, 4, 5] map
	stop if it == 4
	it * 2
end
@assert driftwood == [2, 4, 6], 'stop should keep the partial results collected so far'
