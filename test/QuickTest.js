const { expect } = require("chai");

describe("环境测试", function () {
  it("应该正确设置测试环境", async function () {
    expect(1 + 1).to.equal(2);
  });
});
