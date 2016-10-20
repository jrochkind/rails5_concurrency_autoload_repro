# The only point of this is to get auto-loaded by Rails, depending on
# Rails configuraiton.
class SomeWorker
  def value
    rand(1..100)
  end
end
