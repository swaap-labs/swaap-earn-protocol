<img src="https://docs.swaap.finance/img/brand.png" alt="drawing" width="300"/>

# Swaap Earn Protocol
[![Docs](https://img.shields.io/badge/docs-%F0%9F%93%84-blue)](https://docs.swaap.finance/)
[![tests](https://github.com/swaap-labs/swaap-earn-protocol/actions/workflows/tests.yml/badge.svg)](https://github.com/swaap-labs/swaap-earn-protocol/actions/workflows/tests.yml) 
[![lints](https://github.com/swaap-labs/swaap-earn-protocol/actions/workflows/lints.yml/badge.svg)](https://github.com/swaap-labs/swaap-earn-protocol/actions/workflows/lints.yml) 
[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)


Swaap Earn Protocol contracts.

### Development

**Getting Started**

Before attempting to setup the repo, first make sure you have Foundry installed and updated, which can be done [here](https://github.com/foundry-rs/foundry#installation).

**Building**

Install Foundry dependencies and build the project.

```bash
forge install
```

```bash
forge build
```

To install new libraries.

```bash
forge install <GITHUB_USER>/<REPO>
```

Example

```bash
forge install transmissions11/solmate
```

Whenever you install new libraries using Foundry, make sure to update your `remappings.txt` file.

**Testing**

Before running the tests, rename `sample.env` to `.env`, and add your RPC urls specified.

You can then run the tests with Foundry:

```bash
npm run test
```
or

```bash
forge test
```

To run a specific test file use:

```bash
forge test --match-path "path-to-file"
```
