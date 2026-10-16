import { chmodSync, copyFileSync, mkdirSync } from 'fs';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');

// Make the build/index.js file executable
chmodSync(join(root, 'build', 'index.js'), 0o755);

// Copy the GDScript helper next to the compiled server
mkdirSync(join(root, 'build', 'scripts'), { recursive: true });
copyFileSync(
  join(root, 'src', 'scripts', 'godot_operations.gd'),
  join(root, 'build', 'scripts', 'godot_operations.gd')
);

console.log('Build scripts completed successfully!');
