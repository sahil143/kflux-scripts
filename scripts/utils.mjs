const DELAY = 10000;

// Function to get current namespace
export async function getCurrentNamespace() {
  try {
    const result =
      await $`kubectl config view --minify -o jsonpath='{..namespace}'`;
    return result.stdout.trim() || "default";
  } catch (error) {
    return "default";
  }
}

// Function to prompt for namespace
export async function promptForNamespace(currentNs) {
  console.log(chalk.blue(`Current namespace is: ${currentNs}`));
  const useCurrentNs = await question(
    chalk.yellow(
      `Do you want to use the current namespace "${currentNs}"? (y/n) `
    )
  );

  if (useCurrentNs.toLowerCase() === "y") {
    return currentNs;
  }

  const newNs = await question(chalk.yellow("Enter the namespace to use: "));
  return newNs.trim();
}

export async function promptForApplications(params) {}

// sleep function
export async function sleep(time) {
  return await new Promise((resolve) => setTimeout(resolve, time));
}

export async function createResource(config, type = "resource") {
  const delay = Math.random() * (DELAY * 2 - DELAY) + 10;
  try {
    await $`kubectl apply --validate=false -f - <<< ${JSON.stringify(config)}`;
    console.log(chalk.green(`✓ Created ${type}: ${config.metadata.name}`));
    // Sleep for 10 second. Disclaimer: Do not create too many component wi
    await sleep(delay);
  } catch (error) {
    console.log(
      chalk.red(
        `✗ Failed to create ${type} ${config.metadata.name}: ${error.message}`
      )
    );
    process.exit(1);
  }
}

export async function checkSafetyThresholds(numberOfComponents) {
  if (numberOfComponents > 10) {
    console.log(chalk.yellow("\n  CAUTION:"));
    console.log(
      chalk.yellow(`You are about to create ${numberOfComponents} components.`)
    );
    console.log(
      chalk.yellow("Creating too many components in quick succession might:")
    );
    console.log(chalk.yellow("  - Overload the API server"));
    console.log(chalk.yellow("  - Trigger rate limiting"));
    console.log(chalk.yellow("  - Cause failed deployments"));
    console.log(
      chalk.yellow(
        `\nCurrent delay between components: ${DELAY / 1000} seconds`
      )
    );

    if (DELAY < 10000) {
      console.log(
        chalk.yellow(
          `\nRecommended: Use a delay of at least 10 seconds between components`
        )
      );
    }

    const proceed = await question(
      chalk.yellow("\nDo you want to proceed? (y/N) ")
    );
    return proceed.toLowerCase() === "y";
  }
  return true;
}

export function appendRandomString({ min, max } = { min: 0, max: 40 }) {
  const chars =
    "abcdefghijklmnopqrstuvwxyz0123456789";
  const length = Math.floor(Math.random() * (max - min + 1)) + min; // Random length between min and max

  const randomString = Array.from(
    { length },
    () => chars[Math.floor(Math.random() * chars.length)]
  ).join("");

  return randomString;
}
