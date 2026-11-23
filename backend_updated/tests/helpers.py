from unittest.mock import MagicMock


def make_result(**methods):
    """Build a fake SQLAlchemy Result, e.g. make_result(scalar_one_or_none=None)."""
    result = MagicMock()
    for name, value in methods.items():
        getattr(result, name).return_value = value
    return result


def where_clause(statement) -> str:
    """The WHERE part of a compiled statement ('' if it has none).

    Checking the whole SQL string is not enough: column names such as
    `is_active` always appear in the SELECT list.
    """
    sql = str(statement)
    return sql.split("WHERE", 1)[1] if "WHERE" in sql else ""
