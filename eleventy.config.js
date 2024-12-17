export default async function(eleventyConfig) {
  eleventyConfig.setOutputDirectory("dist");
  eleventyConfig.setInputDirectory("src");
  eleventyConfig.setIncludesDirectory("_includes");
  eleventyConfig.setLayoutsDirectory("_layouts");
  eleventyConfig.setDataDirectory("_data");
};
