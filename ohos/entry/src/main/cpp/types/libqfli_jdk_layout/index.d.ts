export interface InstalledJdkLayout {
  libraryDirectory: string;
  abi: string;
}
export function getLayout(): InstalledJdkLayout;
export function startJava(home: string, libraries: string, cwd: string,
  input: string, output: string, error: string, args: string[]): number;
export function pollJava(pid: number): number | null;
export function cancelJava(pid: number): void;
