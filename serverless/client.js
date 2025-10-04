const API_URL = 'API-URL-GOES-HERE!';

document.getElementById('fetchBtn').onclick = async () => {
  document.getElementById('result').textContent = 'Fetching...';
  try {
    const resp = await fetch(API_URL);
    const data = await resp.json();
    document.getElementById('result').textContent = 'Value from DynamoDB: ' + data.value;
  } catch (err) {
    document.getElementById('result').textContent = 'Error: ' + err;
  }
};