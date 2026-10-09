/// In the SVG files we have templeted variables in the strings.  This method fills in the variables.
export function formatNamed(template: string, values: Record<string, any>): string {
    return template.replace(/{([a-zA-Z0-9_]+)}/g, (match, key) => {
        return typeof values[key] !== 'undefined' ? String(values[key]) : match;
    });
}