import {
  checkSafetyThresholds,
  createResource,
  getCurrentNamespace,
  promptForNamespace,
} from "./utils.mjs";

const NoOfIntegrationTest = 3;

const baseIT = {
  apiVersion: "appstudio.redhat.com/v1beta1",
  kind: "IntegrationTestScenario",
  metadata: {
    name: "application-2-enterprise-contract",
    annotations: { "test.appstudio.openshift.io/kind": "enterprise-contract" },
  },
  spec: {
    application: "test-application-n-components",
    resolverRef: {
      resolver: "git",
      params: [
        {
          name: "url",
          value: "https://github.com/konflux-ci/build-definitions",
        },
        { name: "revision", value: "main" },
        { name: "pathInRepo", value: "pipelines/enterprise-contract.yaml" },
      ],
    },
    params: null,
    contexts: [
      {
        name: "application",
        description:
          "execute the integration test in all cases - this would be the default state",
      },
    ],
  },
};

const resolverRef = [
  {
    resolver: "git",
    params: [
      {
        name: "url",
        value: "https://github.com/konflux-ci/build-definitions",
      },
      { name: "revision", value: "main" },
      { name: "pathInRepo", value: "pipelines/enterprise-contract.yaml" },
    ],
  },
  {
    resolver: "git",
    params: [
      {
        name: "url",
        value: "https://github.com/sahil143/kflux-scripts",
      },
      { name: "revision", value: "main" },
      { name: "pathInRepo", value: "yamls/ec-pipeline.yaml" },
    ],
  },
  {
    resolver: "git",
    params: [
      {
        name: "url",
        value: "https://github.com/sahil143/kflux-scripts",
      },
      { name: "revision", value: "main" },
      { name: "pathInRepo", value: "yamls/ec-pipeline.yaml" },
    ],
  },
];

const allConfigs = [];

// Safety check
const shouldProceed = await checkSafetyThresholds(NoOfIntegrationTest);
if (!shouldProceed) {
  console.log(chalk.blue("Operation cancelled by user"));
  process.exit(0);
}

// Get and confirm namespace
const currentNs = await getCurrentNamespace();
const targetNs = await promptForNamespace(currentNs);

console.log(chalk.green("Using namespace", targetNs));

console.log(
  chalk.grey(`Creating ${NoOfIntegrationTest} integration tests`, allConfigs)
);

for (let i = 5; i <= 5 + NoOfIntegrationTest; i++) {
  // Create a deep copy of the base config
  const config = JSON.parse(JSON.stringify(baseIT));

  // Update with unique names
  config.metadata.name = `test-integration-${i}`;
  config.metadata["namespace"] = targetNs;
  // config.spec['resolverRef'] = resolverRef[Math.floor(Math.random() * 3)];

  allConfigs.push(config);
}

// Apply each config using kubectl with JSON
for (const config of allConfigs) {
  await createResource(config, "integrationtest");
}

console.log(
  chalk.blue(`✨ Successfully processed ${allConfigs.length} integrationtest`)
);
