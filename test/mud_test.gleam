import gleeunit
import woof

pub fn main() -> Nil {
  woof.set_level(woof.Emergency)
  gleeunit.main()
}
