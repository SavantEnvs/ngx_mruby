s="hello"
puts s.upcase.reverse
puts "%d-%s" % [1,"x"]
begin; raise "e"; rescue => e; puts e.message; end
