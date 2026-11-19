(
var f = { |x, y = 2, ...rest| var z = x * y; z + rest.sum };
var g = #{ arg a; a.squared };
var e = (freq: 440, amp: 0.1);
f.(3, 4, 5, 6) + g.value(2) + e[\freq] + [1, 2, 3].collect { |i| i ** 2 }.sum;
x = Array.fill(4, { |i| i.neg }); x[1..2] ++ [x.first, x.last] !? { |a| a.reverse } ?? { nil };
if(x.size > 2) { "big" } { 'small' }; while { false } { 1 }; case { true } { \yes };
1.0e3.round(0.5) min: 2r1010 max: 16rFF; $a.ascii; -inf; pi * 2; `[1, 2];
)
