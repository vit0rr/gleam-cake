import cake/join as j
import cake/select as s
import cake/where as w
import cat
import demo_helper/example_data
import demo_helper/postgres
import gleam/dynamic
import gleam/io
import gleam/list
import pprint

pub fn main() {
  use conn <- postgres.with_connection
  example_data.create_tables_and_insert_rows(conn)

  // NOTICE: This will crash, if the SQL query fails
  let assert Ok(cats) =
    select_query() |> postgres.run_query(dynamic.dynamic, conn)

  io.println("Returned rows: ")
  cats |> pprint.debug

  io.println("Decoded cats (name, age, is_wild, owners_name): ")
  cats |> list.map(cat.from_postgres) |> pprint.debug
}

fn select_query() {
  s.new()
  |> s.selects([
    s.col("cats.name"),
    s.col("cats.age"),
    s.col("cats.is_wild"),
    s.col("owners.name"),
  ])
  |> s.from_table("cats")
  |> s.join(j.inner(
    with: j.table("owners"),
    on: w.col("owners.id") |> w.eq(w.col("cats.owner_id")),
    alias: "owners",
  ))
  |> s.where(w.col("owners.name") |> w.like("%li%"))
  |> s.order_by_asc("cats.name")
  |> s.limit(3)
  |> s.offset(0)
  |> s.epilog("FOR UPDATE")
  |> s.comment("Gets up to 3 cats with their age and owner's name!")
  |> s.to_query
}
