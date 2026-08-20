### Introduction

`for` iterates a collection. Inside the body, `it` is the current element and `at` is its index -- no loop variable to name and declare yourself. The castaways take inventory of what washed ashore from the plane:
###
cargo   := ['water', 'fruit', 'blankets']
manifest := []
for cargo
	manifest.push("`at`: `it`")
end
@assert manifest == ['0: water', '1: fruit', '2: blankets'], 'it/at should pair each element with its index'


### Ranges iterate too

A range is just another iterable -- `for` walks it the same way it walks an array:
###
days_stranded := 0
for 1...5
	days_stranded = it
end
@assert days_stranded == 5, 'range iteration should end on the last value'


### Stride: chunks of N

`by N` groups the collection into chunks of N elements per iteration, instead of one element at a time -- `it` becomes each chunk. Jin pairs up the fish he's caught:
###
fish := ['red', 'blue', 'green', 'yellow', 'orange', 'purple']
pairs := []
for fish by 2
	pairs.push(it)
end
@assert pairs == [['red', 'blue'], ['green', 'yellow'], ['orange', 'purple']], 'stride 2 should chunk into pairs'
