
class Fox [

  define tail "red"

  define call : x [
    x.times : i [
      print "this is a fox!"
    ]
  ]

]

f = Fox.new


-- call method
f.call 2

-- also call method
f 2 
