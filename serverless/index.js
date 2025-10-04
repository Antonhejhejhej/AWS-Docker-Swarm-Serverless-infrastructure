const AWS = require('aws-sdk');
const ddb = new AWS.DynamoDB();
exports.handler = async (event) => {
  const params = {
    TableName: process.env.TABLE_NAME,
    Key: { id: { S: "demo" } }
  };
  try {
    const data = await ddb.getItem(params).promise();
    let value = data.Item ? data.Item.value.S : "No value found";
    return {
      statusCode: 200,
      headers: {
        "Access-Control-Allow-Origin": "*"
      },
      body: JSON.stringify({ value })
    };
  } catch (err) {
    return {
      statusCode: 500,
      headers: {
        "Access-Control-Allow-Origin": "*"
      },
      body: JSON.stringify({ error: err.message })
    };
  }
};