"""Data contracts, asserted without a database.

WHY THIS FILE EXISTS.

Until now, CI covered the application and nothing else. `run_local_ci.sh`
excluded `*/ingest/*` from even the compile step, so roughly two thousand lines
of loader -- every feed declaration, every crosswalk, every metric definition,
the whole DataOps layer -- was not compiled, not linted and not tested. The
platform had a build pipeline and a data pipeline with nothing joining them.

That gap is the reason a broken feed declaration could only ever be discovered
by running a forty-minute load and reading the output.

WHAT IS ASSERTED HERE, AND WHAT IS NOT.

These are STATIC checks: they import the loaders' declarations and assert the
declarations are internally coherent. No network, no database, no fixtures --
so they run on the host interpreter in milliseconds, on every commit.

The checks that need real data live in platform/tests/test_data_contract_live.sh
and run against the live database, because a contract about 6.1 million rows
cannot be verified by reading source.

The split matters: a DB-backed test that SKIPS when the database is absent is
indistinguishable from a test that does not exist, and CI would skip it every
time.
"""
import importlib.util
import pathlib
import sys
import unittest

INGEST = pathlib.Path(__file__).resolve().parents[1] / "ingest"


def _load(name):
    """Import a loader by path without requiring it to be on sys.path.

    The loaders keep `import psycopg` inside main() precisely so this works on
    the host interpreter, which has no psycopg installed and must not grow one:
    installing into the host environment is forbidden by CLAUDE.md, and a
    contract test that can only run inside the ingest container is a contract
    test CI will never run.
    """
    spec = importlib.util.spec_from_file_location(name, INGEST / f"{name}.py")
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


class FeedDeclarationTests(unittest.TestCase):
    """Every feed must be internally consistent before it is ever fetched."""

    @classmethod
    def setUpClass(cls):
        cls.dim = _load("load_dimensional")

    def test_every_measure_names_a_declared_metric(self):
        """A feed pointing at an undeclared metric fails only at load time.

        This is the failure the NHI expansion would have produced ten times over
        if `nhi_visits` had been added to FEEDS and not to METRICS: nine feeds
        load, the tenth dies forty minutes in.
        """
        for key, feed in self.dim.FEEDS.items():
            for mcode, *_ in feed["measures"]:
                self.assertIn(
                    mcode, self.dim.METRICS,
                    f"feed '{key}' measures '{mcode}', which METRICS does not "
                    f"declare")

    def test_stock_and_flow_are_declared_not_defaulted(self):
        """measure_type is the guard against summing a level over time.

        管理中個案數 summed across a year counts one patient once per day of a
        6-9 month course -- roughly 200x. The guard only works if every metric
        actually carries a type the database will accept.
        """
        for code, (_zh, mtype, _unit, _notes) in self.dim.METRICS.items():
            self.assertIn(
                mtype, ("flow", "stock", "rate"),
                f"metric '{code}' has measure_type '{mtype}', which violates "
                f"the CHECK constraint in migration 006 and would fail at load")

    def test_disease_is_not_encoded_in_the_metric_name(self):
        """The defect migration 012 exists to prevent, caught at commit time.

        The fact table carries disease_id. A metric whose name also names a
        disease encodes it twice, and nothing stops a row saying
        metric=covid_visits with disease=enterovirus.
        """
        shared = {}
        for key, feed in self.dim.FEEDS.items():
            for mcode, *_ in feed["measures"]:
                shared.setdefault(mcode, set()).add(feed["disease"])
        # nhi_visits is deliberately shared across 11 diseases -- that is the
        # fix, not the bug. What must not happen is a metric used by exactly one
        # disease whose NAME repeats that disease, which is how the duplication
        # creeps back in one feed at a time.
        for mcode, diseases in shared.items():
            if len(diseases) != 1:
                continue
            disease = next(iter(diseases))
            stem = disease.split("_")[0]
            if mcode.startswith("tb_"):
                continue  # tuberculosis metrics are genuinely TB-specific counts
            self.assertFalse(
                mcode.startswith(stem) and mcode != stem,
                f"metric '{mcode}' is used by only the '{disease}' disease and "
                f"repeats its name. The disease belongs in disease_id, not in "
                f"the metric code -- see migration 012")

    def test_feed_groups_reference_real_feeds(self):
        """A group naming a feed that does not exist loads silently short.

        `--sources nhi_all` expanding to ten of eleven feeds looks exactly like
        a successful run.
        """
        for group, members in self.dim.FEED_GROUPS.items():
            for m in members:
                self.assertIn(
                    m, self.dim.FEEDS,
                    f"group '{group}' names feed '{m}', which does not exist")

    def test_nhi_all_covers_every_nhi_feed(self):
        """The group must not drift behind the feed list.

        Adding a twelfth NHI disease and forgetting the group is a silent
        under-load, not an error.
        """
        declared = {k for k, f in self.dim.FEEDS.items()
                    if f["code"].startswith("cdc-nhi")}
        grouped = set(self.dim.FEED_GROUPS["nhi_all"])
        self.assertEqual(
            declared - grouped, set(),
            "these NHI feeds exist but nhi_all does not include them; "
            "`--sources nhi_all` would silently load a subset")

    def test_levels_match_the_database_check_constraints(self):
        """spatial/temporal levels are CHECK-constrained in migration 004.

        A typo here fails at INSERT, after the fetch and the parse.
        """
        for key, feed in self.dim.FEEDS.items():
            self.assertIn(feed["spatial"],
                          ("country", "county", "township", "village", "point"),
                          f"feed '{key}' spatial level would fail the CHECK")
            self.assertIn(feed["temporal"], ("day", "epi_week", "year", "static"),
                          f"feed '{key}' temporal level would fail the CHECK")

    def test_denominator_declaration_matches_the_measures(self):
        """`denom` and the measure tuples must agree.

        They are two statements of the same fact, written in different places,
        and nothing else compares them.
        """
        for key, feed in self.dim.FEEDS.items():
            has_denom_column = any(m[2] for m in feed["measures"])
            self.assertEqual(
                bool(feed["denom"]), has_denom_column,
                f"feed '{key}' declares denom={feed['denom']} but its measures "
                f"{'do not name' if feed['denom'] else 'name'} a denominator "
                f"column")


class RegistryDeclarationTests(unittest.TestCase):
    """戶政司 loader: the vocabulary-drift defence must stay complete."""

    @classmethod
    def setUpClass(cls):
        cls.reg = _load("load_registry")

    def test_every_household_type_declares_both_vocabularies(self):
        """110-112 and 114 publish English keys; 113 publishes Chinese.

        Not a clean boundary -- 113 is the odd one out. A field that lost one of
        its two spellings would work for four years and silently return nothing
        for one.
        """
        for entry in self.reg.HOUSEHOLD_TYPES:
            key, zh, total_c, m_c, f_c = entry
            for col in (total_c, m_c, f_c):
                self.assertEqual(
                    len(col), 2,
                    f"household type '{key}' column {col} must declare both the "
                    f"English and Chinese spelling")
                self.assertTrue(
                    any(any(ord(ch) > 0x3000 for ch in c) for c in col),
                    f"household type '{key}' column {col} has no Chinese "
                    f"spelling -- year 113 would resolve to nothing")

    def test_alias_raises_rather_than_returning_none(self):
        """The single most important behaviour in that loader.

        Returning None on an unknown vocabulary is what turns a column rename
        into a table full of NULLs that reads as missing data.
        """
        with self.assertRaises(KeyError):
            self.reg.alias({"unexpected_key": "1"}, "district_code", "區域別代碼")

    def test_roc_year_conversion(self):
        """民國 114 = 西元 2025. Off by one here mislabels every row."""
        self.assertEqual(114 + self.reg.ROC_OFFSET, 2025)
        self.assertEqual(110 + self.reg.ROC_OFFSET, 2021)

    def test_every_dataset_names_metrics_that_migration_008_created(self):
        known = {"population", "households", "household_heads"}
        for key, spec in self.reg.DATASETS.items():
            for m in spec["metrics"]:
                self.assertIn(
                    m, known,
                    f"dataset '{key}' declares metric '{m}', which migration "
                    f"008 does not create")


class NormalisationTests(unittest.TestCase):
    """The 臺/台 fold that every place-name lookup depends on."""

    @classmethod
    def setUpClass(cls):
        cls.dim = _load("load_dimensional")

    def test_normalisation_folds_the_variant_and_strips_whitespace(self):
        self.assertEqual(self.dim.norm("臺中市"), "台中市")
        self.assertEqual(self.dim.norm(" 台中市 "), "台中市")
        self.assertEqual(self.dim.norm("台　中　市"), "台中市")  # ideographic space

    def test_normalisation_handles_none_and_empty(self):
        """204 NLSC villages have empty names; norm() must not raise on them."""
        self.assertEqual(self.dim.norm(None), "")
        self.assertEqual(self.dim.norm(""), "")


if __name__ == "__main__":
    unittest.main()
