"""The model-registry contract. Project-neutral, deliberately small.

WHAT THIS FILE IS FOR

Every project that trains a model eventually needs the same four facts about
it, in a place a reviewer can read: what it is, how to build it, what it was
configured with, and what it does with missing values. Those facts are normally
scattered -- a constructor call in the training script, a different constructor
call in the publisher, a name retyped into the INSERT, and a hyperparameter
table in a slide. They then disagree, and the disagreement is invisible,
because every artefact still renders.

So a project declares a dict of specs and this module is the only thing that
decides whether a spec is admissible. It contains NO domain knowledge: no
feature names, no disease, no NaN rates, no thresholds. Those belong in the
project's own entries, where they are reviewable in context.

WHAT IT DELIBERATELY DOES NOT DO

No plugin discovery, no entry points, no YAML, no importlib by string. A
registry that can load a model whose declaration nobody read is a worse version
of the problem it was built to solve. Adding a model is a code change in the
project, reviewed like any other.

USING IT IN A NEW PROJECT

    import model_registry as mreg

    MODELS = {"Ridge": {...}}                 # your entries
    spec = mreg.get(MODELS, args.algorithm)   # refuses unknown names
    est  = spec["build"](spec["hyperparams"]) # unfitted, per fold

and one test that calls mreg.validate_all(MODELS). That test is the whole
enforcement: an entry that would be refused at selection time must not be
listable, or the catalogue advertises models that do not run.
"""

# The six fields, and why each is not optional. The text is the error message a
# project author sees, so it says what to do, not just what is missing.
REQUIRED_FIELDS = {
    "family": "what class of model this is (tree ensemble / linear / neural / "
              "hybrid). Two runs from different families are not automatically "
              "comparable, and a reviewer can only see that if it is written "
              "down beside the score.",
    "build": "a callable taking the hyperparams dict and returning an UNFITTED "
             "estimator. Unfitted matters: fitting belongs to the fold, and an "
             "entry that returns something already fitted breaks the split "
             "silently -- every downstream number still renders.",
    "hyperparams": "the dict passed to build(), recorded verbatim as the run's "
                   "provenance. It must be the SAME object that is passed, not "
                   "a description of it; a description drifts.",
    "handles_nan": "whether the estimator accepts NaN features. This is the "
                   "field that decides whether the entry needs a nan_policy.",
    "nan_policy": "required when handles_nan is False: what is done to missing "
                  "values instead, in one line. Missingness is usually a "
                  "signal, not noise, so the substitution must be stated where "
                  "it is reviewable rather than buried in a preprocessing step.",
    "deterministic": "whether the same seed and the same rows give the same "
                     "numbers. False is allowed but must be declared -- a "
                     "non-reproducible score cannot be used as evidence, and a "
                     "gate that compares to four decimal places would be "
                     "comparing noise without knowing it.",
}


class RegistryError(ValueError):
    """Raised for a spec that must not be used. Never downgraded to a warning:
    a warning about provenance is read by nobody and the run continues."""


def validate(name, spec):
    """Check one entry. Returns the spec so it can be used inline."""
    if not isinstance(spec, dict):
        raise RegistryError(f"model {name!r}: spec must be a dict, got "
                            f"{type(spec).__name__}")
    missing = [f for f in REQUIRED_FIELDS if f not in spec]
    if missing:
        detail = "\n".join(f"  {f}: {REQUIRED_FIELDS[f]}" for f in missing)
        raise RegistryError(f"model {name!r} is missing registry field(s):\n{detail}")
    if not callable(spec["build"]):
        raise RegistryError(f"model {name!r}: build must be callable")
    if not isinstance(spec["hyperparams"], dict):
        raise RegistryError(f"model {name!r}: hyperparams must be a dict, "
                            f"because it is stored as the run's provenance")
    if not spec["handles_nan"] and not spec["nan_policy"]:
        raise RegistryError(
            f"model {name!r} declares handles_nan=False but no nan_policy. "
            f"A model that cannot take NaN does something to the missing "
            f"values; say what, here, where a reviewer will see it.")
    return spec


def check_buildable(name, spec):
    """Actually call build() and check what comes back.

    validate() only reads the declaration. This runs it, which is what catches
    the two mistakes the declaration cannot express: a build() that raises on
    its own declared hyperparams, and a build() that returns an object which is
    already fitted. The second is the dangerous one -- a pre-fitted estimator
    produces perfectly normal-looking scores that were computed with the test
    rows inside the fit.

    scikit-learn sets n_features_in_ (and other trailing-underscore attributes)
    at fit time, so its absence is the portable signal for "not yet fitted".
    Estimators from other libraries simply will not have it either, which fails
    open here on purpose: this is a check for a specific known defect, not a
    conformance test for every ML library in existence.
    """
    est = spec["build"](spec["hyperparams"])
    for m in ("fit", "predict"):
        if not hasattr(est, m):
            raise RegistryError(f"model {name!r}: build() returned an object "
                                f"with no .{m}()")
    if hasattr(est, "n_features_in_"):
        raise RegistryError(
            f"model {name!r}: build() returned an ALREADY FITTED estimator. "
            f"build() must return an unfitted one -- fitting happens per fold, "
            f"on training rows only. A pre-fitted object scores normally and "
            f"the score is meaningless.")
    return est


def validate_all(models, build=True):
    """Validate every entry. Called by --list-models and by the test suite, so
    a catalogue can never advertise an entry that selection would refuse."""
    if not models:
        raise RegistryError("the registry is empty")
    for name in sorted(models):
        validate(name, models[name])
        if build:
            check_buildable(name, models[name])
    return models


def get(models, name):
    """Select by name. An unknown name is refused WITH the list -- never
    defaulted, because a silent default records one algorithm's name against
    another algorithm's numbers, and every later comparison inherits that."""
    if name not in models:
        raise RegistryError(
            f"unknown --algorithm {name!r}. Registered: "
            f"{', '.join(sorted(models))}. Add an entry to MODELS in the "
            f"project's training script.")
    return validate(name, models[name])


def describe(models, dumps=repr):
    """One block per entry, for --list-models. Everything printed is read from
    the spec: a listing with a retyped literal in it is a fourth copy."""
    out = []
    for name, sp in sorted(models.items()):
        out.append(
            f"{name}\n"
            f"  family        {sp['family']}\n"
            f"  hyperparams   {dumps(sp['hyperparams'])}\n"
            f"  handles_nan   {sp['handles_nan']}\n"
            f"  nan_policy    {sp['nan_policy'] or '-'}\n"
            f"  deterministic {sp['deterministic']}")
    return "\n".join(out)
