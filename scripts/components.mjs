#!/usr/bin/env zx

import {
  checkSafetyThresholds,
  createResource,
  getCurrentNamespace,
  promptForNamespace,
} from "./utils.mjs";
// import { baseApplicationConfig } from "./applications.mjs";

const NumberOfComponent = 25;

const baseComponentConfig = {
  apiVersion: "appstudio.redhat.com/v1alpha1",
  kind: "Component",
  metadata: {
    annotations: {
      "build.appstudio.openshift.io/pipeline":
        '{"name":"docker-build","bundle":"latest"}',
      "build.appstudio.openshift.io/request": "configure-pac",
      "image.redhat.com/generate": '{"visibility": "public"}',
    },
    name: "COMPONENT_METADATA_NAME_PLACEHOLDER",
  },
  spec: {
    componentName: "COMPONENT_NAME_PLACEHOLDER",
    application: "test-application-n-components",
    source: {
      git: {
        url: "https://github.com/sahil143/devfile-sample-code-with-quarkus",
      },
    },
  },
};

const allConfigs = [];

// Safety check
const shouldProceed = await checkSafetyThresholds(NumberOfComponent);
if (!shouldProceed) {
  console.log(chalk.blue("Operation cancelled by user"));
  process.exit(0);
}

// Get and confirm namespace
const currentNs = await getCurrentNamespace();
const targetNs = await promptForNamespace(currentNs);

console.log(chalk.green("Using namespace", targetNs));

// Create application
// console.log(
//   chalk.grey(
//     `Creating application '${baseApplicationConfig.spec.displayName}'(${baseApplicationConfig.metadata.name})`,
//     allConfigs
//   )
// );
// baseApplicationConfig.metadata["namespace"] = targetNs;

// await createResource(baseApplicationConfig, "application");

console.log(chalk.grey(`Creating ${NumberOfComponent} component`, allConfigs));

for (let i = 26; i <= 25 + NumberOfComponent; i++) {
  // Create a deep copy of the base config
  const config = JSON.parse(JSON.stringify(baseComponentConfig));

  // Update with unique names
  config.metadata.name = `devfile-sample-code-with-quarkus-longer-name-new-${i}`;
  config.metadata["namespace"] = targetNs;
  config.spec.componentName = `devfile-sample-code-with-quarkus-longer-name-new-${i}`;

  allConfigs.push(config);
}

// Apply each config using kubectl with JSON
for (const config of allConfigs) {
  await createResource(config, "component");
}

console.log(
  chalk.blue(`✨ Successfully processed ${allConfigs.length} components`)
);
