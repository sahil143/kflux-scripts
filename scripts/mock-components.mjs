#!/usr/bin/env zx

import {
  appendRandomString,
  checkSafetyThresholds,
  createResource,
  getCurrentNamespace,
  promptForNamespace,
} from "./utils.mjs";

const DefaultCount = 25;

async function promptForCount() {
  const raw = await question(
    chalk.yellow(`How many mock Components to create? (default: ${DefaultCount}) `)
  );
  if (!raw.trim()) return DefaultCount;
  const n = parseInt(raw.trim(), 10);
  if (Number.isNaN(n) || n <= 0) return DefaultCount;
  return n;
}

async function promptForPopulateStatus() {
  const raw = await question(
    chalk.yellow('Populate "status" subresource for UI testing? (y/N) ')
  );
  return raw.trim().toLowerCase() === "y";
}

function makeComponentName(i) {
  return `ui-mock-comp-${i}-${appendRandomString({ min: 5, max: 8 })}`;
}

function makeSpec(i) {
  const commonSource = {
    url: "https://github.com/example-org/example-repo",
    dockerfileUri: "Dockerfile",
  };

  // Vary the payload shape to exercise UI edge cases.
  // - some with 0 versions
  // - some with 1 version
  // - some with multiple versions + fields like context/dockerfileUri/skipBuilds/buildPipeline
  const variant = i % 6;

  if (variant === 0) {
    return {
      source: { ...commonSource, versions: [] },
    };
  }

  if (variant === 1) {
    return {
      source: {
        ...commonSource,
        versions: [{ name: "main", revision: "main" }],
      },
    };
  }

  if (variant === 2) {
    return {
      containerImage: "quay.io/example-org/example-component",
      repositorySettings: { commentStrategy: "disable_all" },
      source: {
        ...commonSource,
        versions: [
          { name: "Version_1_0", revision: "ver-1.0" },
          {
            name: "Test",
            revision: "test",
            context: "./test",
            dockerfileUri: "test.Dockerfile",
            skipBuilds: true,
          },
        ],
      },
    };
  }

  if (variant === 3) {
    return {
      skipOffboardingPr: true,
      actions: {
        triggerPushBuild: "main",
        triggerPushBuilds: ["main", "Test"],
        createPipelineConfigurationPr: {
          allVersions: false,
          versions: ["main", "Test"],
        },
      },
      source: {
        ...commonSource,
        versions: [
          { name: "main", revision: "main" },
          { name: "Test", revision: "test" },
        ],
      },
    };
  }

  if (variant === 4) {
    return {
      defaultBuildPipeline: {
        pullAndPush: {
          pipelineSpecFromBundle: { name: "docker-build-oci-ta", bundle: "latest" },
        },
      },
      source: {
        ...commonSource,
        versions: [
          {
            name: "DifferentPipeline",
            revision: "different_branch",
            buildPipeline: {
              pullAndPush: {
                pipelineSpecFromBundle: {
                  name: "docker-build-oci-ta",
                  bundle: "latest",
                },
              },
            },
          },
        ],
      },
    };
  }

  // variant === 5
  return {
    containerImage: "quay.io/example-org/example-component",
    source: {
      ...commonSource,
      versions: Array.from({ length: 10 }, (_, idx) => ({
        name: `v${idx + 1}`,
        revision: `branch-v${idx + 1}`,
      })),
    },
  };
}

function makeStatus(i) {
  const statuses = ["succeeded", "failed"];
  const pick = (arr) => arr[i % arr.length];

  return {
    message: i % 7 === 0 ? "Spec.containerImage is not set / GitHub App is not installed" : "",
    pacRepository: `pac-repo-${i}`,
    containerImage: "quay.io/example-org/example-component",
    versions: [
      {
        name: "main",
        onboardingStatus: pick(statuses),
        revision: "main",
        skipBuilds: false,
        message: i % 5 === 0 ? "pipeline for main branch doesn't exist" : "",
      },
    ],
  };
}

async function patchStatus({ name, namespace, status }) {
  try {
    await $`kubectl patch component ${name} -n ${namespace} --type merge --subresource=status -p ${JSON.stringify(
      { status }
    )}`;
    console.log(chalk.green(`✓ Patched status: ${name}`));
  } catch (error) {
    console.log(
      chalk.red(`✗ Failed to patch status for ${name}: ${error.message}`)
    );
  }
}

const count = await promptForCount();
const populateStatus = await promptForPopulateStatus();

const shouldProceed = await checkSafetyThresholds(count, "mock components");
if (!shouldProceed) {
  console.log(chalk.blue("Operation cancelled by user"));
  process.exit(0);
}

const currentNs = await getCurrentNamespace();
const targetNs = await promptForNamespace(currentNs);

console.log(chalk.green("Using namespace", targetNs));
console.log(chalk.grey(`Creating ${count} mock Components...`));

for (let i = 1; i <= count; i++) {
  const name = makeComponentName(i);
  const config = {
    apiVersion: "kflux.dev/v1alpha1",
    kind: "Component",
    metadata: { name, namespace: targetNs },
    spec: makeSpec(i),
  };

  await createResource(config, "mock component");

  if (populateStatus) {
    await patchStatus({ name, namespace: targetNs, status: makeStatus(i) });
  }
}

console.log(chalk.blue(`✨ Successfully processed ${count} mock components`));

