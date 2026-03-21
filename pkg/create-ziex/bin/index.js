#!/usr/bin/env node

import { intro, outro, text, select, spinner, isCancel, cancel } from '@clack/prompts';
import color from 'picocolors';
import { downloadTemplate } from 'giget';
import { replaceInFile } from 'replace-in-file';

import path from 'node:path';

const STATIC_TEMPLATES = [
  { value: 'starter', label: 'Vercel', hint: 'Ziex starter' },
  { value: 'vercel', label: 'Vercel', hint: 'Ziex on Vercel' },
  { value: 'cloudflare', label: 'Cloudflare', hint: 'Ziex on Cloudflare' },
];

async function fetchGitHubTemplates() {
  const res = await fetch('https://api.github.com/orgs/ziex-dev/repos');
  const repos = await res.json();
  return repos
    .filter((r) => r.name.startsWith('template-'))
    .map((r) => {
      const name = r.name.replace('template-', '');
      return {
        value: name,
        label: name.charAt(0).toUpperCase() + name.slice(1),
        hint: r.description || '',
      };
    });
}

async function main() {
  console.log();
  intro(color.bgCyan(color.black(' Create Ziex App ')));

  // Start fetching templates immediately in the background
  const templatesFetch = fetchGitHubTemplates().catch(() => null);

  // 1. Gather User Input
  const project = await text({
    message: 'Where should we create your project?',
    placeholder: './my-ziex-app',
    validate: (value) => {
      if (!value) return 'Please enter a path.';
    },
  });

  if (isCancel(project)) {
    cancel('Operation cancelled.');
    process.exit(0);
  }

  // By now the user has been typing — give the fetch a short grace period
  // in case it hasn't resolved yet, then fall back to the static list.
  const dynamicTemplates = await Promise.race([
    templatesFetch,
    new Promise((resolve) => setTimeout(resolve, 500, null)),
  ]);

  const template = await select({
    message: `Pick a template${dynamicTemplates ? '' : ' (showing cached list)'}`,
    options: dynamicTemplates ?? STATIC_TEMPLATES,
  });

  const s = spinner();
  const targetDir = path.resolve(process.cwd(), project);

  // 2. Download from GitHub
  s.start('Downloading template...');
  try {
    // Uses giget to fetch from: github:ziex-dev/templates/templates/<name>
    await downloadTemplate(`github:ziex-dev/template-${template}`, {
      dir: targetDir,
      force: true,
    });
    s.stop('Template downloaded successfully!');
  } catch (err) {
    s.stop('Failed to download template', 1);
    console.error(err);
    process.exit(1);
  }

  // 3. Perform String Replacements
  s.start('Customizing project files...');
  try {
    const projectName = sanitizeProjectName(path.basename(targetDir));
    await replaceInFile({
      files: `${targetDir}/**/*`,
      from: /ziex_app/g,
      to: projectName,
    });
    s.stop('Project customized!');
  } catch (err) {
    s.stop('Replacement failed', 1);
  }

  outro(`Successfully created ${color.cyan(project)}!`);
  console.log(`\n  cd ${project}\n  zig build dev\n`);
}

// Make sure project name is suported Zig identifier
function sanitizeProjectName(name) {
  return name.replace(/[^a-zA-Z0-9_]/g, '_');
}

main().catch(console.error);