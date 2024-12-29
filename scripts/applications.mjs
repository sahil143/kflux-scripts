import { appendRandomString } from "./utils.mjs";
import {
  checkSafetyThresholds,
  createResource,
  getCurrentNamespace,
  promptForNamespace,
} from "./utils.mjs";

const NoOfApplications = 20;

export const baseApplicationConfig = {
  apiVersion: 'appstudio.redhat.com/v1alpha1',
  kind: 'Application',
  metadata: {
    name: 'test-application-n-components',
    namespace: 'NAMESPACE',
    annotations: { 'application.thumbnail': '9' },
  },
  spec: { displayName: 'Testing Application (100 components)' },
};

const allConfigs = [];

// Safety check
const shouldProceed = await checkSafetyThresholds(NoOfApplications);
if (!shouldProceed) {
  console.log(chalk.blue("Operation cancelled by user"));
  process.exit(0);
}

// Get and confirm namespace
const currentNs = await getCurrentNamespace();
const targetNs = await promptForNamespace(currentNs);

console.log(chalk.green("Using namespace", targetNs));

console.log(chalk.grey(`Creating ${NoOfApplications} applications`, allConfigs));

for (let i = 11; i <= NoOfApplications; i++) {
  // Create a deep copy of the base config
  const config = JSON.parse(JSON.stringify(baseApplicationConfig));

  // Update with unique names
  config.metadata.name = `test-application-${i}-${appendRandomString()}`;
  config.metadata["namespace"] = targetNs;
  config.spec.displayName = `test-application-${i}`;

  allConfigs.push(config);
}

// Apply each config using kubectl with JSON
for (const config of allConfigs) {
  await createResource(config, "application");
}

console.log(
  chalk.blue(`✨ Successfully processed ${allConfigs.length} applications`)
);



