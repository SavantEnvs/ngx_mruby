h={a: 1,"b"=>[1,2,3]}
h.each{|k,v| puts k.to_s}
puts h.map{|k,v| v}.inspect
