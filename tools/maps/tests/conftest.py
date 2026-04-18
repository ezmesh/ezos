def pytest_addoption(parser):
    parser.addoption(
        "--regen", action="store_true", default=False,
        help="Regenerate golden fixtures from the current renderer output")
