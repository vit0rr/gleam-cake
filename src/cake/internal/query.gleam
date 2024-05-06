import cake/param.{type Param, NullParam}
import cake/prepared_statement.{type PreparedStatement}

// import cake/stdlib/iox
import cake/stdlib/listx
import cake/stdlib/stringx
import gleam/int
import gleam/list
import gleam/string

// TODO: case expressions for WHERE, SELECT and others

// ┌───────────────────────────────────────────────────────────────────────────┐
// │  Builder                                                                  │
// └───────────────────────────────────────────────────────────────────────────┘

pub fn builder_new(
  query qry: Query,
  prepared_statement_prefix prp_stm_prfx: String,
) -> PreparedStatement {
  prp_stm_prfx
  |> prepared_statement.new()
  |> builder_apply(qry)
}

pub fn builder_apply(
  prepared_statement prp_stm: PreparedStatement,
  query qry: Query,
) -> PreparedStatement {
  case qry {
    Select(query: qry) -> qry |> select_builder(prp_stm, _)
    Combined(query: qry) -> qry |> combined_builder(prp_stm, _)
  }
}

// ┌───────────────────────────────────────────────────────────────────────────┐
// │  Combined Builder                                                         │
// └───────────────────────────────────────────────────────────────────────────┘

pub fn combined_builder(
  prepared_statement prp_stm: PreparedStatement,
  select cq: CombinedQuery,
) -> PreparedStatement {
  // TODO: what happens if multiple select queries have different type signatures for their columns?
  // -> In prepared statements we can already check this and return either an OK() or an Error()
  // The error would return that the column types missmatch
  // The user probably let assets this then?
  prp_stm
  |> union_builder_apply_command_sql(cq)
  |> union_builder_apply_to_sql(cq, union_builder_maybe_add_order_sql)
  |> limit_offset_apply(cq.limit_offset)
  |> epilog_apply(cq.epilog)
}

pub fn union_builder_apply_command_sql(
  prepared_statement prp_stm: PreparedStatement,
  select cq: CombinedQuery,
) -> PreparedStatement {
  let combination = case cq.kind {
    Union -> "UNION"
    UnionAll -> "UNION ALL"
    Except -> "EXCEPT"
    ExceptAll -> "EXCEPT ALL"
    Intersect -> "INTERSECT"
    IntersectAll -> "INTERSECT ALL"
  }

  cq.select_queries
  |> list.fold(
    prp_stm,
    fn(acc: PreparedStatement, sq: SelectQuery) -> PreparedStatement {
      case acc == prp_stm {
        True -> acc |> select_builder(sq)
        False -> {
          acc
          |> prepared_statement.with_sql(" " <> combination <> " ")
          |> select_builder(sq)
        }
      }
    },
  )
}

fn union_builder_apply_to_sql(
  prepared_statement prp_stm: PreparedStatement,
  query qry: CombinedQuery,
  maybe_fun mb_fun: fn(CombinedQuery) -> String,
) -> PreparedStatement {
  prepared_statement.with_sql(prp_stm, mb_fun(qry))
}

fn union_builder_maybe_add_order_sql(query qry: CombinedQuery) -> String {
  case qry.order_by {
    [] -> ""
    _ -> {
      let order_bys =
        qry.order_by
        |> list.map(fn(ordrb: OrderByPart) -> String {
          ordrb.column <> " " <> order_by_part_to_sql(ordrb)
        })

      " ORDER BY " <> string.join(order_bys, ", ")
    }
  }
}

// ┌───────────────────────────────────────────────────────────────────────────┐
// │  Select Builder                                                           │
// └───────────────────────────────────────────────────────────────────────────┘

pub fn select_builder(
  prepared_statement prp_stm: PreparedStatement,
  select sq: SelectQuery,
) -> PreparedStatement {
  prp_stm
  |> select_builder_apply_to_sql(sq, select_builder_maybe_add_select_sql)
  |> select_builder_maybe_apply_from_sql(sq)
  |> select_builder_maybe_apply_join(sq)
  |> select_builder_maybe_apply_where(sq)
  |> select_builder_apply_to_sql(sq, select_builder_maybe_add_order_sql)
  |> select_builder_maybe_apply_limit_offset(sq)
}

fn select_builder_apply_to_sql(
  prepared_statement prp_stm: PreparedStatement,
  query qry: SelectQuery,
  maybe_fun mb_fun: fn(SelectQuery) -> String,
) -> PreparedStatement {
  prepared_statement.with_sql(prp_stm, mb_fun(qry))
}

fn select_builder_maybe_add_select_sql(query qry: SelectQuery) -> String {
  case qry.select {
    [] -> "SELECT *"
    _ -> "SELECT " <> stringx.map_join(qry.select, select_part_to_sql, ", ")
  }
}

fn select_builder_maybe_apply_from_sql(
  prp_stm: PreparedStatement,
  query qry: SelectQuery,
) -> PreparedStatement {
  prp_stm |> from_part_append_to_prepared_statement(qry.from)
}

fn select_builder_maybe_apply_where(
  prepared_statement prp_stm: PreparedStatement,
  query qry: SelectQuery,
) -> PreparedStatement {
  prp_stm |> where_part_apply_clause(qry.where)
}

fn select_builder_maybe_apply_join(
  prepared_statement prp_stm: PreparedStatement,
  query qry: SelectQuery,
) -> PreparedStatement {
  prp_stm |> join_parts_apply_as_clause(qry.join)
}

fn select_builder_maybe_add_order_sql(query qry: SelectQuery) -> String {
  case qry.order_by {
    [] -> ""
    _ -> {
      let order_bys =
        qry.order_by
        |> list.map(fn(ordrb: OrderByPart) -> String {
          ordrb.column <> " " <> order_by_part_to_sql(ordrb)
        })

      " ORDER BY " <> string.join(order_bys, ", ")
    }
  }
}

fn select_builder_maybe_apply_limit_offset(
  prepared_statement prp_stm: PreparedStatement,
  select_query slct_qry: SelectQuery,
) -> PreparedStatement {
  let lmt_offst = limit_offset_get(slct_qry)
  // |> iox.dbg_label("lmt_offst")

  prp_stm
  |> limit_offset_apply(lmt_offst)
}

// ┌───────────────────────────────────────────────────────────────────────────┐
// │  Query                                                                    │
// └───────────────────────────────────────────────────────────────────────────┘

pub type Query {
  // TODO: Maybe move these to a ReadQuery wrapper type?
  // And then maybe have all the constructors right here?
  // ReadQuery -> SelectQuery | CombinedQuery
  Select(query: SelectQuery)
  Combined(query: CombinedQuery)
  // TODO: Maybe move these to a WriteQuery wrapper type?
  // TODO: ... but then have them there directly?
  // Insert(query: InsertQuery
  // Update(query: UpdateQuery)
  // Delete(query: DeleteQuery)
}

pub fn query_select_wrap(query qry: SelectQuery) -> Query {
  Select(qry)
}

pub fn query_combined_wrap(query qry: CombinedQuery) -> Query {
  Combined(qry)
}

// ┌───────────────────────────────────────────────────────────────────────────┐
// │  OrderByDirectionPart                                                     │
// └───────────────────────────────────────────────────────────────────────────┘

pub type OrderByPart {
  OrderByColumnPart(column: String, direction: OrderByDirectionPart)
}

pub type OrderByDirectionPart {
  Asc
  Desc
  AscNullsFirst
  DescNullsFirst
}

pub fn order_by_part_to_sql(order_by_part ordbpt: OrderByPart) {
  case ordbpt.direction {
    Asc -> "ASC NULLS LAST"
    Desc -> "DESC NULLS LAST"
    AscNullsFirst -> "ASC NULLS FIRST"
    DescNullsFirst -> "DESC NULLS FIRST"
  }
}

// ┌───────────────────────────────────────────────────────────────────────────┐
// │  Limit & Offset Part                                                      │
// └───────────────────────────────────────────────────────────────────────────┘

pub opaque type LimitOffsetPart {
  LimitOffset(limit: Int, offset: Int)
  LimitNoOffset(limit: Int)
  NoLimitOffset
}

pub fn limit_offset_new(limit lmt: Int, offset offst: Int) -> LimitOffsetPart {
  case lmt >= 0, offst >= 0 {
    True, True -> LimitOffset(limit: lmt, offset: offst)
    True, False -> LimitNoOffset(limit: lmt)
    False, _ -> NoLimitOffset
  }
}

pub fn limit_new(limit lmt: Int) -> LimitOffsetPart {
  case lmt >= 0 {
    True -> LimitNoOffset(limit: lmt)
    False -> NoLimitOffset
  }
}

pub fn limit_offset_apply(
  prepared_statement prp_stm: PreparedStatement,
  limit_part lmt_prt: LimitOffsetPart,
) -> PreparedStatement {
  case lmt_prt {
    LimitOffset(limit: lmt, offset: offst) ->
      " LIMIT " <> int.to_string(lmt) <> " OFFSET " <> int.to_string(offst)
    LimitNoOffset(limit: lmt) -> " LIMIT " <> int.to_string(lmt)
    NoLimitOffset -> ""
  }
  |> prepared_statement.with_sql(prp_stm, _)
}

pub fn limit_offset_get(select_query slct_qry: SelectQuery) -> LimitOffsetPart {
  slct_qry.limit_offset
}

// ┌───────────────────────────────────────────────────────────────────────────┐
// │  Combined Query                                                           │
// └───────────────────────────────────────────────────────────────────────────┘

pub type CombinedKind {
  Union
  UnionAll
  Except
  // Notice: ExceptAll Does not work on SQLite
  ExceptAll
  Intersect
  // NOTICE: IntersectAll Does not work on SQLite
  IntersectAll
}

// List of SQL parts that will be used to build a combined query
// such as UNION queries.
pub type CombinedQuery {
  CombinedQuery(
    kind: CombinedKind,
    select_queries: List(SelectQuery),
    limit_offset: LimitOffsetPart,
    order_by: List(OrderByPart),
    // Epilog allows you to append raw SQL to the end of queries.
    // You should never put raw user data into epilog.
    epilog: EpilogPart,
  )
}

pub fn combined_union_query_new(
  select_queries slct_qrys: List(SelectQuery),
) -> CombinedQuery {
  Union |> combined_query_new(slct_qrys)
}

pub fn combined_union_all_query_new(
  select_queries slct_qrys: List(SelectQuery),
) -> CombinedQuery {
  UnionAll |> combined_query_new(slct_qrys)
}

pub fn combined_except_query_new(
  select_queries slct_qrys: List(SelectQuery),
) -> CombinedQuery {
  Except |> combined_query_new(slct_qrys)
}

pub fn combined_except_all_query_new(
  select_queries slct_qrys: List(SelectQuery),
) -> CombinedQuery {
  ExceptAll |> combined_query_new(slct_qrys)
}

pub fn combined_intersect_query_new(
  select_queries slct_qrys: List(SelectQuery),
) -> CombinedQuery {
  Intersect |> combined_query_new(slct_qrys)
}

pub fn combined_intersect_all_query_new(
  select_queries slct_qrys: List(SelectQuery),
) -> CombinedQuery {
  IntersectAll |> combined_query_new(slct_qrys)
}

fn combined_query_new(
  kind: CombinedKind,
  select_queries: List(SelectQuery),
) -> CombinedQuery {
  select_queries
  |> combined_query_remove_order_by_from_selects()
  |> CombinedQuery(
    kind: kind,
    select_queries: _,
    limit_offset: NoLimitOffset,
    order_by: [],
    epilog: NoEpilogPart,
  )
}

fn combined_query_remove_order_by_from_selects(
  select_queries slct_qrys: List(SelectQuery),
) -> List(SelectQuery) {
  slct_qrys
  |> list.map(fn(slct_qry) { SelectQuery(..slct_qry, order_by: []) })
}

pub fn combined_get_select_queries(
  combined_query cq: CombinedQuery,
) -> List(SelectQuery) {
  cq.select_queries
}

// ▒▒▒ LIMIT & OFFSET ▒▒▒

pub fn combined_query_set_limit(
  query qry: CombinedQuery,
  limit lmt: Int,
) -> CombinedQuery {
  let limit_offset = limit_new(lmt)
  CombinedQuery(..qry, limit_offset: limit_offset)
}

pub fn combined_query_set_limit_and_offset(
  query qry: CombinedQuery,
  limit lmt: Int,
  offset offst: Int,
) -> CombinedQuery {
  let limit_offset = limit_offset_new(limit: lmt, offset: offst)
  CombinedQuery(..qry, limit_offset: limit_offset)
}

// ▒▒▒ ORDER BY ▒▒▒

pub fn combined_query_order_asc(
  query qry: CombinedQuery,
  by ordb: String,
) -> CombinedQuery {
  do_combined_order_by(qry, OrderByColumnPart(ordb, Asc), True)
}

pub fn combined_query_order_asc_nulls_first(
  query qry: CombinedQuery,
  by ordb: String,
) -> CombinedQuery {
  do_combined_order_by(qry, OrderByColumnPart(ordb, AscNullsFirst), True)
}

pub fn combined_query_order_asc_replace(
  query qry: CombinedQuery,
  by ordb: String,
) -> CombinedQuery {
  do_combined_order_by(qry, OrderByColumnPart(ordb, Asc), False)
}

pub fn combined_query_order_asc_nulls_first_replace(
  query qry: CombinedQuery,
  by ordb: String,
) -> CombinedQuery {
  do_combined_order_by(qry, OrderByColumnPart(ordb, AscNullsFirst), False)
}

pub fn combined_query_order_desc(
  query qry: CombinedQuery,
  by ordb: String,
) -> CombinedQuery {
  do_combined_order_by(qry, OrderByColumnPart(ordb, Desc), True)
}

pub fn combined_query_order_desc_nulls_first(
  query qry: CombinedQuery,
  by ordb: String,
) -> CombinedQuery {
  do_combined_order_by(qry, OrderByColumnPart(ordb, DescNullsFirst), True)
}

pub fn combined_query_order_desc_replace(
  query qry: CombinedQuery,
  by ordb: String,
) -> CombinedQuery {
  do_combined_order_by(qry, OrderByColumnPart(ordb, Desc), False)
}

pub fn combined_query_order_desc_nulls_first_replace(
  query qry: CombinedQuery,
  by ordb: String,
) -> CombinedQuery {
  do_combined_order_by(qry, OrderByColumnPart(ordb, DescNullsFirst), False)
}

pub fn combined_query_order(
  query qry: CombinedQuery,
  by ordb: String,
  direction dir: OrderByDirectionPart,
) -> CombinedQuery {
  do_combined_order_by(qry, OrderByColumnPart(ordb, dir), True)
}

pub fn combined_query_order_replace(
  query qry: CombinedQuery,
  by ordb: String,
  direction dir: OrderByDirectionPart,
) -> CombinedQuery {
  do_combined_order_by(qry, OrderByColumnPart(ordb, dir), False)
}

fn do_combined_order_by(
  query qry: CombinedQuery,
  by ordb: OrderByPart,
  append append: Bool,
) -> CombinedQuery {
  case append {
    True ->
      CombinedQuery(..qry, order_by: qry.order_by |> listx.append_item(ordb))
    False -> CombinedQuery(..qry, order_by: listx.wrap(ordb))
  }
}

// ┌───────────────────────────────────────────────────────────────────────────┐
// │  Select Query                                                             │
// └───────────────────────────────────────────────────────────────────────────┘

// List of SQL parts that will be used to build a select query.
pub type SelectQuery {
  SelectQuery(
    from: FromPart,
    // comment: String,
    // modifier: String,
    // with: String,
    select: List(SelectPart),
    // distinct: String,
    join: List(JoinPart),
    where: WherePart,
    // group_by: String,
    // having: String,
    // window: String,
    // values: String, ?
    // with_recursive: String, ?
    limit_offset: LimitOffsetPart,
    order_by: List(OrderByPart),
    epilog: EpilogPart,
  )
}

// ▒▒▒ NEW ▒▒▒

pub fn select_query_new(
  from from: FromPart,
  select select: List(SelectPart),
) -> SelectQuery {
  SelectQuery(
    from: from,
    select: select,
    where: NoWherePart,
    join: [],
    order_by: [],
    limit_offset: NoLimitOffset,
    epilog: NoEpilogPart,
  )
}

pub fn select_query_new_from(from from: FromPart) -> SelectQuery {
  SelectQuery(
    from: from,
    select: [],
    join: [],
    where: NoWherePart,
    order_by: [],
    limit_offset: NoLimitOffset,
    epilog: NoEpilogPart,
  )
}

pub fn select_query_new_select(select select: List(SelectPart)) -> SelectQuery {
  SelectQuery(
    from: NoFromPart,
    select: select,
    where: NoWherePart,
    join: [],
    order_by: [],
    limit_offset: NoLimitOffset,
    epilog: NoEpilogPart,
  )
}

// ▒▒▒ FROM ▒▒▒

pub fn select_query_set_from(
  query qry: SelectQuery,
  from from: FromPart,
) -> SelectQuery {
  SelectQuery(..qry, from: from)
}

// ▒▒▒ SELECT ▒▒▒

pub fn select_query_select(
  select_query sq: SelectQuery,
  select_parts slct_prts: List(SelectPart),
) -> SelectQuery {
  SelectQuery(..sq, select: list.append(sq.select, slct_prts))
}

pub fn select_query_select_replace(
  query qry: SelectQuery,
  select select: List(SelectPart),
) -> SelectQuery {
  SelectQuery(..qry, select: select)
}

// ▒▒▒ WHERE ▒▒▒

pub fn select_query_set_where(
  query qry: SelectQuery,
  where whr: WherePart,
) -> SelectQuery {
  SelectQuery(..qry, where: whr)
}

// ▒▒▒ JOIN ▒▒▒

pub fn select_query_set_join(
  query qry: SelectQuery,
  join jn: List(JoinPart),
) -> SelectQuery {
  SelectQuery(..qry, join: jn)
}

// ▒▒▒ ORDER BY ▒▒▒

pub fn select_query_order_asc(
  query qry: SelectQuery,
  by ordb: String,
) -> SelectQuery {
  do_select_order_by(qry, OrderByColumnPart(ordb, Asc), True)
}

pub fn select_query_order_asc_nulls_first(
  query qry: SelectQuery,
  by ordb: String,
) -> SelectQuery {
  do_select_order_by(qry, OrderByColumnPart(ordb, AscNullsFirst), True)
}

pub fn select_query_order_asc_replace(
  query qry: SelectQuery,
  by ordb: String,
) -> SelectQuery {
  do_select_order_by(qry, OrderByColumnPart(ordb, Asc), False)
}

pub fn select_query_order_asc_nulls_first_replace(
  query qry: SelectQuery,
  by ordb: String,
) -> SelectQuery {
  do_select_order_by(qry, OrderByColumnPart(ordb, AscNullsFirst), False)
}

pub fn select_query_order_desc(
  query qry: SelectQuery,
  by ordb: String,
) -> SelectQuery {
  do_select_order_by(qry, OrderByColumnPart(ordb, Desc), True)
}

pub fn select_query_order_desc_nulls_first(
  query qry: SelectQuery,
  by ordb: String,
) -> SelectQuery {
  do_select_order_by(qry, OrderByColumnPart(ordb, DescNullsFirst), True)
}

pub fn select_query_order_desc_replace(
  query qry: SelectQuery,
  by ordb: String,
) -> SelectQuery {
  do_select_order_by(qry, OrderByColumnPart(ordb, Desc), False)
}

pub fn select_query_order_desc_nulls_first_replace(
  query qry: SelectQuery,
  by ordb: String,
) -> SelectQuery {
  do_select_order_by(qry, OrderByColumnPart(ordb, DescNullsFirst), False)
}

pub fn select_query_order(
  query qry: SelectQuery,
  by ordb: String,
  direction dir: OrderByDirectionPart,
) -> SelectQuery {
  do_select_order_by(qry, OrderByColumnPart(ordb, dir), True)
}

pub fn select_query_order_replace(
  query qry: SelectQuery,
  by ordb: String,
  direction dir: OrderByDirectionPart,
) -> SelectQuery {
  do_select_order_by(qry, OrderByColumnPart(ordb, dir), False)
}

fn do_select_order_by(
  query qry: SelectQuery,
  by ordb: OrderByPart,
  append append: Bool,
) -> SelectQuery {
  case append {
    True ->
      SelectQuery(..qry, order_by: qry.order_by |> listx.append_item(ordb))
    False -> SelectQuery(..qry, order_by: listx.wrap(ordb))
  }
}

// ▒▒▒ LIMIT & OFFSET ▒▒▒

pub fn select_query_set_limit(
  query qry: SelectQuery,
  limit lmt: Int,
) -> SelectQuery {
  let limit_offset = limit_new(lmt)
  SelectQuery(..qry, limit_offset: limit_offset)
}

pub fn select_query_set_limit_and_offset(
  query qry: SelectQuery,
  limit lmt: Int,
  offset offst: Int,
) -> SelectQuery {
  let limit_offset = limit_offset_new(limit: lmt, offset: offst)
  SelectQuery(..qry, limit_offset: limit_offset)
}

// ┌───────────────────────────────────────────────────────────────────────────┐
// │  From Part                                                                │
// └───────────────────────────────────────────────────────────────────────────┘

pub type FromPart {
  // TODO: check if the table does indeed exist
  FromTable(name: String)
  FromSubQuery(query: Query, alias: String)
  NoFromPart
}

pub fn from_part_from_table(table_name tbl_nm: String) -> FromPart {
  FromTable(tbl_nm)
}

pub fn from_part_from_sub_query(
  sub_query sb_qry: Query,
  alias als: String,
) -> FromPart {
  FromSubQuery(sb_qry, als)
}

pub fn from_part_append_to_prepared_statement(
  prepared_statement prp_stm: PreparedStatement,
  part prt: FromPart,
) -> PreparedStatement {
  case prt {
    FromTable(tbl) -> prepared_statement.with_sql(prp_stm, " FROM " <> tbl)
    FromSubQuery(sb_qry, als) ->
      prp_stm
      |> prepared_statement.with_sql(" FROM (")
      |> builder_apply(sb_qry)
      |> prepared_statement.with_sql(") AS " <> als)
    NoFromPart -> prp_stm
  }
}

// ┌───────────────────────────────────────────────────────────────────────────┐
// │  Select Part                                                              │
// └───────────────────────────────────────────────────────────────────────────┘

// TODO MAYBE use something like this:

// type SelectValue {
//   SelectAggregateFunction(List(SelectValue))
//   SelectFunction(List(SelectValue))
//   SelectColumn(String)
//   SelectParam(Param)
//   // SelectCase?
// }

// Then during processing or values
// inject prepared statement parameters.

pub type SelectPart {
  // Strings are arbitrary SQL strings
  // Aliases rename fields
  SelectString(string: String)
  SelectStringAlias(string: String, alias: String)
  // Columns are:
  // - auto prefixed? by their corresponding tables if not given
  // - checked if they exist
  SelectColumn(column: String)
  SelectColumnAlias(column: String, alias: String)
  // RawSelect(string: String, parameters: List(Param))
}

pub fn select_part_from(s: String) -> SelectPart {
  // TODO: check if the table does indeed exist
  SelectString(s)
}

pub fn select_part_to_sql(part prt: SelectPart) {
  case prt {
    SelectString(string) -> string
    SelectStringAlias(string, alias) -> string <> " AS " <> alias
    SelectColumn(column) -> column
    SelectColumnAlias(column, alias) -> column <> " AS " <> alias
  }
}

// ┌───────────────────────────────────────────────────────────────────────────┐
// │  Where Part                                                               │
// └───────────────────────────────────────────────────────────────────────────┘

// TODO MAYBE instead of:
//
// `WhereColEqualCol(a_column: String, b_column: String)`
//
// use
//
// `WhereEqual(WhereValue, WhereValue)`
//
// then during processing or values
// inject prepared statement parameters.

// type WhereValue {
//   WhereFunction(List(WhereValue))
//   WhereColumn(String)
//   WhereParam(Param)
//   // WhereCase?
// }

pub type WherePart {
  // Column A to column B comparison
  WhereColEqualCol(a_column: String, b_column: String)
  WhereColLowerCol(a_column: String, b_column: String)
  WhereColLowerOrEqualCol(a_column: String, b_column: String)
  WhereColGreaterCol(a_column: String, b_column: String)
  WhereColGreaterOrEqualCol(a_column: String, b_column: String)
  WhereColNotEqualCol(a_column: String, b_column: String)
  // Column to parameter comparison
  WhereColEqualParam(column: String, parameter: Param)
  WhereColLowerParam(column: String, parameter: Param)
  WhereColLowerOrEqualParam(column: String, parameter: Param)
  WhereColGreaterParam(column: String, parameter: Param)
  WhereColGreaterOrEqualParam(column: String, parameter: Param)
  WhereColNotEqualParam(column: String, parameter: Param)
  WhereColLike(a_column: String, paramter: String)
  WhereColILike(a_column: String, parameter: String)
  // MAYBE add:
  // - WhereColBetweenParamAndParam(column: String, lower: Param, upper: Param)
  // - WhereColBetweenColAndParam(column: String, lower: String, upper: Param)
  // - WhereColBetweenParamAndCol(column: String, lower: Param, upper: String)
  // - WhereColBetweenColAndCol(column: String, lower: String, upper: String)
  // NOTICE: Sqlite does not support `SIMILAR TO`
  WhereColSimilarTo(a_column: String, parameter: String)
  // Parameter to column comparison
  WhereParamEqualCol(parameter: Param, column: String)
  WhereParamLowerCol(parameter: Param, column: String)
  WhereParamLowerOrEqualCol(parameter: Param, column: String)
  WhereParamGreaterCol(parameter: Param, column: String)
  WhereParamGreaterOrEqualCol(parameter: Param, column: String)
  WhereParamNotEqualCol(parameter: Param, column: String)
  // Column IS [NOT] TRUE/FALSE
  WhereColIsBool(column: String, bool: Bool)
  WhereColIsNotBool(column: String, bool: Bool)
  // MAYBE add: https://wiki.postgresql.org/wiki/Is_distinct_from
  // - WhereColIsDistinctFromCol(a_column: String, b_column: String)
  // - WhereColIsDistinctFromParam(column: String, parameter: Param)
  // Logical operators
  AndWhere(parts: List(WherePart))
  OrWhere(parts: List(WherePart))
  // TODO: XorWhere(List(WherePart))
  NotWhere(part: WherePart)
  // Column contains value
  WhereColInParams(column: String, parameters: List(Param))
  // Sub Query
  // WhereColInSubquery(column: String, sub_query: Query)
  // WhereColAllSubquery(column: String, sub_query: Query)
  // WhereColAnySubquery(column: String, sub_query: Query)
  // WhereColExistsSubquery(sub_query: Query)
  // WhereColEqualSubquery(column: String, sub_query: Query)
  // WhereColLowerSubquery(column: String, sub_query: Query)
  // WhereColLowerOrEqualSubquery(column: String, sub_query: Query)
  // WhereColGreaterSubquery(column: String, sub_query: Query)
  // WhereColGreaterOrEqualSubquery(column: String, sub_query: Query)
  // WhereColNotEqualSubquery(column: String, sub_query: Query)
  NoWherePart
}

fn where_part_apply(
  prepared_statement prp_stm: PreparedStatement,
  part prt: WherePart,
) -> PreparedStatement {
  case prt {
    WhereColEqualCol(a_col, b_col) ->
      prp_stm |> where_part_apply_comparison_col_col(a_col, "=", b_col)
    WhereColLowerCol(a_col, b_col) ->
      prp_stm |> where_part_apply_comparison_col_col(a_col, "<", b_col)
    WhereColLowerOrEqualCol(a_col, b_col) ->
      prp_stm |> where_part_apply_comparison_col_col(a_col, "<=", b_col)
    WhereColGreaterCol(a_col, b_col) ->
      prp_stm |> where_part_apply_comparison_col_col(a_col, ">", b_col)
    WhereColGreaterOrEqualCol(a_col, b_col) ->
      prp_stm |> where_part_apply_comparison_col_col(a_col, ">=", b_col)
    WhereColNotEqualCol(a_col, b_col) ->
      prp_stm |> where_part_apply_comparison_col_col(a_col, "<>", b_col)
    WhereColEqualParam(col, NullParam) ->
      prp_stm |> prepared_statement.with_sql(col <> " IS NULL")
    WhereColEqualParam(col, param) ->
      prp_stm |> where_part_apply_comparison_col_param(col, "=", param)
    WhereColLowerParam(col, param) ->
      prp_stm |> where_part_apply_comparison_col_param(col, "<", param)
    WhereColLowerOrEqualParam(col, param) ->
      prp_stm |> where_part_apply_comparison_col_param(col, "<=", param)
    WhereColGreaterParam(col, param) ->
      prp_stm |> where_part_apply_comparison_col_param(col, ">", param)
    WhereColGreaterOrEqualParam(col, param) ->
      prp_stm |> where_part_apply_comparison_col_param(col, ">=", param)
    WhereColNotEqualParam(col, NullParam) ->
      prp_stm |> prepared_statement.with_sql(col <> " IS NOT NULL")
    WhereColNotEqualParam(col, param) ->
      prp_stm |> where_part_apply_comparison_col_param(col, "<>", param)
    WhereColLike(col, param) ->
      prp_stm
      |> where_part_apply_comparison_col_param(
        col,
        "LIKE",
        param.StringParam(param),
      )
    WhereColILike(col, param) ->
      prp_stm
      |> where_part_apply_comparison_col_param(
        col,
        "ILIKE",
        param.StringParam(param),
      )
    WhereColSimilarTo(col, param) ->
      prp_stm
      |> where_part_apply_comparison_col_param(
        col,
        "SIMILAR TO",
        param.StringParam(param),
      )
      |> prepared_statement.with_sql(" ESCAPE '/'")
    WhereParamEqualCol(NullParam, col) ->
      prp_stm |> prepared_statement.with_sql(col <> " IS NULL")
    WhereParamEqualCol(param, col) ->
      prp_stm |> where_part_apply_comparison_param_col(param, "=", col)
    WhereParamLowerCol(param, col) ->
      prp_stm |> where_part_apply_comparison_param_col(param, "<", col)
    WhereParamLowerOrEqualCol(param, col) ->
      prp_stm |> where_part_apply_comparison_param_col(param, "<=", col)
    WhereParamGreaterCol(param, col) ->
      prp_stm |> where_part_apply_comparison_param_col(param, ">", col)
    WhereParamGreaterOrEqualCol(param, col) ->
      prp_stm |> where_part_apply_comparison_param_col(param, ">=", col)
    WhereParamNotEqualCol(NullParam, col) ->
      prp_stm |> prepared_statement.with_sql(col <> " IS NOT NULL")
    WhereParamNotEqualCol(param, col) ->
      prp_stm |> where_part_apply_comparison_param_col(param, "<>", col)
    WhereColIsBool(col, True) ->
      prp_stm |> prepared_statement.with_sql(col <> " IS TRUE")
    WhereColIsBool(col, False) ->
      prp_stm |> prepared_statement.with_sql(col <> " IS FALSE")
    WhereColIsNotBool(col, True) ->
      prp_stm |> prepared_statement.with_sql(col <> " IS NOT TRUE")
    WhereColIsNotBool(col, False) ->
      prp_stm |> prepared_statement.with_sql(col <> " IS NOT FALSE")
    AndWhere(prts) ->
      prp_stm |> where_part_apply_logical_sql_operator("AND", prts)
    OrWhere(prts) ->
      prp_stm |> where_part_apply_logical_sql_operator("OR", prts)
    NotWhere(prt) -> {
      prp_stm
      |> prepared_statement.with_sql("NOT (")
      |> where_part_apply(prt)
      |> prepared_statement.with_sql(")")
    }
    WhereColInParams(col, params) ->
      prp_stm |> where_part_apply_column_in_params(col, params)
    // WhereColEqualSubquery(column: col, sub_query: sb_qry) ->
    //   todo as iox.inspect(#(col, sb_qry))
    // WhereColLowerSubquery(column: col, sub_query: sb_qry) ->
    //   todo as iox.inspect(#(col, sb_qry))
    // WhereColLowerOrEqualSubquery(column: col, sub_query: sb_qry) ->
    //   todo as iox.inspect(#(col, sb_qry))
    // WhereColGreaterSubquery(column: col, sub_query: sb_qry) ->
    //   todo as iox.inspect(#(col, sb_qry))
    // WhereColGreaterOrEqualSubquery(column: col, sub_query: sb_qry) ->
    //   todo as iox.inspect(#(col, sb_qry))
    // WhereColNotEqualSubquery(column: col, sub_query: sb_qry) ->
    //   todo as iox.inspect(#(col, sb_qry))
    NoWherePart -> prp_stm
  }
}

pub fn where_part_apply_clause(
  prepared_statement prp_stm: PreparedStatement,
  part prt: WherePart,
) -> PreparedStatement {
  case prt {
    NoWherePart -> prp_stm
    _ -> {
      prp_stm
      |> prepared_statement.with_sql(" WHERE ")
      |> where_part_apply(prt)
    }
  }
}

pub fn join_parts_apply_as_clause(
  prepared_statement prp_stm: PreparedStatement,
  parts prts: List(JoinPart),
) -> PreparedStatement {
  prts
  |> list.fold(
    prp_stm,
    fn(acc: PreparedStatement, prt: JoinPart) -> PreparedStatement {
      let apply_join = fn(acc, join_command) {
        acc
        |> prepared_statement.with_sql(" " <> join_command <> " ")
        |> join_part_apply(prt)
      }
      let apply_on = fn(acc, on) {
        acc
        |> prepared_statement.with_sql(" ON ")
        |> where_part_apply(on)
      }
      case prt {
        CrossJoin(_, _) -> acc |> apply_join("CROSS JOIN")
        InnerJoin(_, _, on: on) ->
          acc |> apply_join("INNER JOIN") |> apply_on(on)
        LeftOuterJoin(_, _, on: on) ->
          acc |> apply_join("LEFT OUTER JOIN") |> apply_on(on)
        RightOuterJoin(_, _, on: on) ->
          acc |> apply_join("RIGHT OUTER JOIN") |> apply_on(on)
        FullOuterJoin(_, _, on: on) ->
          acc |> apply_join("FULL OUTER JOIN") |> apply_on(on)
      }
    },
  )
}

fn where_part_apply_comparison_col_col(
  prp_stm: PreparedStatement,
  a_col: String,
  sql_operator: String,
  b_col: String,
) {
  prp_stm
  |> prepared_statement.with_sql(a_col <> " " <> sql_operator <> " " <> b_col)
}

fn where_part_apply_comparison_col_param(
  prp_stm: PreparedStatement,
  col: String,
  sql_operator: String,
  param: Param,
) {
  let next_placeholder = prepared_statement.next_placeholder(prp_stm)

  prp_stm
  |> prepared_statement.with_sql_and_param(
    col <> " " <> sql_operator <> " " <> next_placeholder,
    param,
  )
}

fn where_part_apply_comparison_param_col(prp_stm, param, sql_operator, col) {
  let next_placeholder = prepared_statement.next_placeholder(prp_stm)

  prp_stm
  |> prepared_statement.with_sql_and_param(
    next_placeholder <> " " <> sql_operator <> " " <> col,
    param,
  )
}

fn where_part_apply_logical_sql_operator(
  prepared_statement prp_stm: PreparedStatement,
  operator oprtr: String,
  parts prts: List(WherePart),
) {
  let new_prep_stm = prp_stm |> prepared_statement.with_sql("(")

  prts
  |> list.fold(
    new_prep_stm,
    fn(acc: PreparedStatement, prt: WherePart) -> PreparedStatement {
      case acc == new_prep_stm {
        True -> acc |> where_part_apply(prt)
        False ->
          acc
          |> prepared_statement.with_sql(" " <> oprtr <> " ")
          |> where_part_apply(prt)
      }
    },
  )
  |> prepared_statement.with_sql(")")
}

fn where_part_apply_column_in_params(
  prepared_statement prp_stm: PreparedStatement,
  column col: String,
  parameters params: List(Param),
) -> PreparedStatement {
  let new_prep_stm = prp_stm |> prepared_statement.with_sql(col <> " IN (")

  params
  |> list.fold(
    new_prep_stm,
    fn(acc: PreparedStatement, param: Param) -> PreparedStatement {
      let new_sql = case acc == new_prep_stm {
        True -> prepared_statement.next_placeholder(prp_stm)
        False -> ", " <> prepared_statement.next_placeholder(acc)
      }
      prepared_statement.with_sql_and_param(acc, new_sql, param)
    },
  )
  |> prepared_statement.with_sql(")")
}

// ┌───────────────────────────────────────────────────────────────────────────┐
// │  Join Part                                                                │
// └───────────────────────────────────────────────────────────────────────────┘

pub type Join {
  JoinTable(table: String)
  JoinSubQuery(sub_query: Query)
}

pub type JoinPart {
  CrossJoin(with: Join, alias: String)
  InnerJoin(with: Join, alias: String, on: WherePart)
  LeftOuterJoin(with: Join, alias: String, on: WherePart)
  RightOuterJoin(with: Join, alias: String, on: WherePart)
  FullOuterJoin(with: Join, alias: String, on: WherePart)
}

fn join_part_apply(
  prepared_statement prp_stm: PreparedStatement,
  join_part jp: JoinPart,
) -> PreparedStatement {
  case jp.with {
    JoinTable(table: tbl) ->
      prp_stm |> prepared_statement.with_sql(tbl <> " AS " <> jp.alias)
    JoinSubQuery(sub_query: sb_qry) ->
      prp_stm
      |> prepared_statement.with_sql("(")
      |> builder_apply(sb_qry)
      |> prepared_statement.with_sql(") AS " <> jp.alias)
  }
}

// ┌───────────────────────────────────────────────────────────────────────────┐
// │  Epilog Part                                                              │
// └───────────────────────────────────────────────────────────────────────────┘

pub opaque type EpilogPart {
  Epilog(string: String)
  NoEpilogPart
}

pub fn epilog_new(epilog: String) -> EpilogPart {
  case epilog {
    "" -> NoEpilogPart
    _ -> Epilog(string: epilog)
  }
}

pub fn epilog_apply(
  prepared_statement prp_stm: PreparedStatement,
  epilog_part epl_prt: EpilogPart,
) -> PreparedStatement {
  case epl_prt {
    NoEpilogPart -> prp_stm
    Epilog(string: epl) -> epl |> prepared_statement.with_sql(prp_stm, _)
  }
}
