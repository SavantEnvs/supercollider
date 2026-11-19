("KAT: " ++ (3 + 4)).postln;
("KAT: " ++ [1, 2, 3].collect({ |x| x * x }).sum).postln;
("KAT: " ++ "supercollider".reverse.toUpper).postln;
("KAT: " ++ "{ |a, b = 2| a ** b }".compile.value.value(5)).postln;
("KAT: " ++ (freq: 69).at(\freq).midicps).postln;
0.exit;
