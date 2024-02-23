<img src="https://docs.swaap.finance/img/brand.png" alt="drawing" width="300"/>

# Swaap Cellar Contracts
[![Docs](https://img.shields.io/badge/docs-%F0%9F%93%84-blue)](https://docs.swaap.finance/)
[![tests](https://github.com/swaap-labs/swaap-earn-protocol/actions/workflows/tests.yml/badge.svg)](https://github.com/swaap-labs/swaap-earn-protocol/actions/workflows/tests.yml) 
[![lints](https://github.com/swaap-labs/swaap-earn-protocol/actions/workflows/lints.yml/badge.svg)](https://github.com/swaap-labs/swaap-earn-protocol/actions/workflows/lints.yml) 
[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)


Cellar contracts.

### Development

**Getting Started**

Before attempting to setup the repo, first make sure you have Foundry installed and updated, which can be done [here](https://github.com/foundry-rs/foundry#installation).

**Building**

Install Foundry dependencies and build the project.

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

Before running test, rename `sample.env` to `.env`, and add your mainnet RPC. If you want to deploy any contracts, you will need that networks RPC, a Private Key, and an Etherscan key(if you want foundry to verify the contracts).
Note in order to run tests against forked mainnet, your RPC must be an archive node. My favorite archive node is [Alchemy](https://www.alchemy.com).

Run tests with Foundry:

```bash
npm run forkTest
```
