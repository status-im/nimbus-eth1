# Adding documentation

The documentation visible on [https://fluffy.guide](https://fluffy.guide) is generated with [mkdocs](https://www.mkdocs.org/getting-started/).

If you want to be able to dry run any changes you make, you best install mkdocs locally.

All the documentation related files can be found under the `./portal/docs/the_fluffy_book` directory.

## How to test and add documentation changes

- Install `mkdocs`
- Install Material for MkDocs by running `pip install mkdocs-material mkdocs-mermaid2-plugin`.
- Make your changes to the documentation
- Run `mkdocs serve` from the `./portal/docs/the_fluffy_book` directory and test your changes. Alter as required.
- Push your changes to a PR on nimbus-eth1

When the PR gets merged, a CI job will run that deploys automatically the changes to [https://fluffy.guide](https://fluffy.guide).
