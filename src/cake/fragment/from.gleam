pub type FromFragment {
  FromString(String)
  // TODO: check if the table does indeed exist
  FromTable(String)
  NoFromFragment
}

pub fn from_table(s: String) -> FromFragment {
  FromTable(s)
}

pub fn to_sql(fragment frgmt: FromFragment) {
  case frgmt {
    FromString(s) -> " FROM " <> s
    FromTable(s) -> " FROM " <> s
    NoFromFragment -> ""
  }
}