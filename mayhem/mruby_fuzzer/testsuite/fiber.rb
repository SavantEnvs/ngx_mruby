f=Fiber.new{ Fiber.yield 1; 2 }
puts f.resume
puts (1..5).select(&:even?).inspect
puts 2**70
