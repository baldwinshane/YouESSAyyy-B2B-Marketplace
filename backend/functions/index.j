const functions = require('firebase-functions');
const admin = require('firebase-admin');
const axios = require('axios');

admin.initializeApp();

exports.createSupplier = functions
  .runWith({ memory: '128MB', timeoutSeconds: 60 })
  .region('us-central1')
  .https.onCall(async (data, context) => {
    if (!context.auth) {
      throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated.');
    }

    const userDoc = admin.firestore().collection('rateLimits').doc(context.auth.uid);
    const rateLimit = await userDoc.get();
    const now = Date.now();
    const oneDayMs = 24 * 60 * 60 * 1000;
    if (rateLimit.exists && rateLimit.data().lastCall > now - oneDayMs && rateLimit.data().count >= 100) {
      throw new functions.https.HttpsError('resource-exhausted', 'Rate limit exceeded. Try again tomorrow.');
    }
    await userDoc.set({ lastCall: now, count: (rateLimit.data()?.count || 0) + 1 }, { merge: true });

    const { companyName, address } = data;
    if (!companyName || typeof companyName !== 'string' || companyName.trim().length < 3) {
      throw new functions.https.HttpsError('invalid-argument', 'Company name must be a string with at least 3 characters.');
    }
    if (!address || typeof address !== 'string' || address.trim().length < 5) {
      throw new functions.https.HttpsError('invalid-argument', 'Address must be a string with at least 5 characters.');
    }

    const supplierDoc = await admin.firestore().collection('suppliers').doc(context.auth.uid).get();
    if (supplierDoc.exists) {
      throw new functions.https.HttpsError('already-exists', 'User is already registered as a supplier.');
    }

    try {
      const googleMapsResponse = await axios.get(`https://maps.googleapis.com/maps/api/geocode/json?address=${encodeURIComponent(address)}&key=${process.env.GOOGLE_MAPS_API_KEY}`);
      const isUSAddress = googleMapsResponse.data.results.some(result => 
        result.address_components.some(comp => comp.short_name === 'US')
      );
      if (!isUSAddress) {
        throw new functions.https.HttpsError('invalid-argument', 'Address must be in the USA.');
      }
    } catch (error) {
      functions.logger.error('Address validation failed', { error: error.message });
      throw new functions.https.HttpsError('invalid-argument', `Address validation failed: ${error.message}`);
    }

    const sanitizedCompanyName = companyName.replace(/[^a-zA-Z0-9]/g, '').toLowerCase();
    const matrixUsername = `@${sanitizedCompanyName}:matrix.youessayyy.com`;
    const matrixPassword = Math.random().toString(36).slice(-8);

    try {
      const userCheck = await axios.get(`https://matrix.youessayyy.com/_synapse/admin/v2/users/${matrixUsername}`, {
        headers: { Authorization: `Bearer ${process.env.MATRIX_ADMIN_TOKEN}` }
      });
      if (userCheck.data.name) {
        throw new functions.https.HttpsError('already-exists', `Matrix username ${matrixUsername} already exists.`);
      }
    } catch (error) {
      if (error.response?.status !== 404) {
        functions.logger.error('Matrix user check failed', { error: error.message });
        throw new functions.https.HttpsError('internal', `Failed to check Matrix user: ${error.message}`);
      }
    }

    let attempts = 0;
    const maxAttempts = 3;
    while (attempts < maxAttempts) {
      try {
        await axios.post('https://matrix.youessayyy.com/_synapse/admin/v2/users/' + matrixUsername, {
          password: matrixPassword,
          displayname: companyName
        }, {
          headers: { Authorization: `Bearer ${process.env.MATRIX_ADMIN_TOKEN}` }
        });
        functions.logger.info('Matrix user created', { matrixUsername });
        break;
      } catch (error) {
        attempts++;
        if (attempts === maxAttempts) {
          functions.logger.error('Matrix user creation failed after retries', { error: error.message });
          throw new functions.https.HttpsError('internal', `Failed to create Matrix user: ${error.message}`);
        }
        await new Promise(resolve => setTimeout(resolve, 1000));
      }
    }

    try {
      await admin.firestore().collection('suppliers').doc(context.auth.uid).set({
        userId: context.auth.uid,
        matrixUsername,
        companyName,
        status: 'pending',
        address,
        createdAt: admin.firestore.FieldValue.serverTimestamp()
      });
      functions.logger.info('Supplier stored in Firestore', { userId: context.auth.uid });
      return { success: true, matrixUsername };
    } catch (error) {
      functions.logger.error('Firestore write failed', { error: error.message });
      throw new functions.https.HttpsError('internal', `Failed to store supplier: ${error.message}`);
    }
  });
