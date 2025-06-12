#!/usr/bin/env zx

import {
  appendRandomString,
  checkSafetyThresholds,
  createResource,
  getCurrentNamespace,
  promptForNamespace,
} from "./utils.mjs";

// Default number of releases
const DefaultNumberOfReleases = 5;

const baseReleaseConfig = {
  apiVersion: "appstudio.redhat.com/v1alpha1",
  kind: "Release",
  metadata: {
    namespace: "NAMESPACE",
    labels: {}
  },
  spec: {
    releasePlan: "RELEASE_PLAN_PLACEHOLDER",
    snapshot: "SNAPSHOT_PLACEHOLDER",
    data: {
      releaseNotes: {
        references: "",
        synopsis: "",
        topic: "",
        description: ""
      }
    }
  }
};

async function promptForReleaseDetails() {
  console.log(chalk.blue("\n=== Release Configuration ==="));
  
  const releasePlan = await question(
    chalk.yellow("Enter the release plan name: ")
  );
  
  const snapshot = await question(
    chalk.yellow("Enter the snapshot name: ")
  );
  
  const numberOfReleases = await question(
    chalk.yellow(`Enter the number of releases to create (default: ${DefaultNumberOfReleases}): `)
  );
  
  const releaseCount = numberOfReleases.trim() 
    ? parseInt(numberOfReleases.trim(), 10) 
    : DefaultNumberOfReleases;

  if (isNaN(releaseCount) || releaseCount <= 0) {
    console.log(chalk.red("Invalid number of releases. Using default value."));
    return {
      releasePlan: releasePlan.trim(),
      snapshot: snapshot.trim(),
      count: DefaultNumberOfReleases
    };
  }

  return {
    releasePlan: releasePlan.trim(),
    snapshot: snapshot.trim(),
    count: releaseCount
  };
}

// Get release configuration from user
const { releasePlan, snapshot, count } = await promptForReleaseDetails();

// Validate inputs
if (!releasePlan || !snapshot) {
  console.log(chalk.red("❌ Release plan and snapshot are required!"));
  process.exit(1);
}

console.log(chalk.green(`\n📋 Configuration:`));
console.log(chalk.green(`   Release Plan: ${releasePlan}`));
console.log(chalk.green(`   Snapshot: ${snapshot}`));
console.log(chalk.green(`   Number of Releases: ${count}`));

// Safety check
const shouldProceed = await checkSafetyThresholds(count, 'releases');
if (!shouldProceed) {
  console.log(chalk.blue("Operation cancelled by user"));
  process.exit(0);
}

// Get and confirm namespace
const currentNs = await getCurrentNamespace();
const targetNs = await promptForNamespace(currentNs);

console.log(chalk.green(`Using namespace: ${targetNs}`));

const allConfigs = [];

console.log(chalk.grey(`\n🚀 Creating ${count} releases...`));

for (let i = 1; i <= count; i++) {
  // Create a deep copy of the base config
  const config = JSON.parse(JSON.stringify(baseReleaseConfig));
  
  // Generate unique name
  const uniqueSuffix = `${i}-${appendRandomString({ min: 5, max: 8 })}`;
  
  // Update with specific values
  config.metadata.name = `${releasePlan}-${uniqueSuffix}`;
  config.metadata.namespace = targetNs;
  config.spec.releasePlan = releasePlan;
  config.spec.snapshot = snapshot;
  
  // Optional: Add some variation to release notes
  config.spec.data.releaseNotes.synopsis = `Automated release ${i} of ${count}`;
  config.spec.data.releaseNotes.description = `Generated release using kflux-scripts`;
  
  allConfigs.push(config);
}

// Apply each config using kubectl with JSON
for (const config of allConfigs) {
  await createResource(config, "release");
}

console.log(
  chalk.blue(`✨ Successfully processed ${allConfigs.length} releases`)
);
console.log(chalk.green(`📦 All releases created with:`));
console.log(chalk.green(`   - Release Plan: ${releasePlan}`));
console.log(chalk.green(`   - Snapshot: ${snapshot}`));
