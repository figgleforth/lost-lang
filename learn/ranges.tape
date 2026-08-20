``` Introduction

Four range operators, all built from the same `...` shape, differing only in whether the start and end are included. `...` is fully inclusive -- both ends stay in:
```
days := []
for 1...5
	days.push(it)
end
@assert days == [1, 2, 3, 4, 5], '... should include both ends'


``` ..< excludes the end

Everything up to, but not including, the end:
```
days2 := []
for 1..<5
	days2.push(it)
end
@assert days2 == [1, 2, 3, 4], '..< should exclude the end'


``` >.. excludes the start

Everything after the start, end included:
```
days3 := []
for 1>..5
	days3.push(it)
end
@assert days3 == [2, 3, 4, 5], '>.. should exclude the start'


``` >.< excludes both ends

Neither the start nor the end is included -- only what's strictly between them:
```
days4 := []
for 1>.<5
	days4.push(it)
end
@assert days4 == [2, 3, 4], '>.< should exclude both ends'
